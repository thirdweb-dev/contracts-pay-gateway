// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.22;

/// @author thirdweb

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { EIP712 } from "./utils/EIP712.sol";

import { SafeTransferLib } from "./lib/SafeTransferLib.sol";
import { ECDSA } from "./lib/ECDSA.sol";

contract PaymentsGateway is EIP712, Ownable, ReentrancyGuard {
    using ECDSA for bytes32;

    /*///////////////////////////////////////////////////////////////
                        State, constants, structs
    //////////////////////////////////////////////////////////////*/

    bytes32 private constant PAYOUTINFO_TYPEHASH =
        keccak256("PayoutInfo(bytes32 clientId,address payoutAddress,uint256 feeBPS)");
    bytes32 private constant REQUEST_TYPEHASH =
        keccak256(
            "PayRequest(bytes32 clientId,bytes32 transactionId,address tokenAddress,uint256 tokenAmount,uint256 expirationTimestamp,PayoutInfo[] payouts,address forwardAddress,bytes data)PayoutInfo(bytes32 clientId,address payoutAddress,uint256 feeBPS)"
        );
    address private constant NATIVE_TOKEN_ADDRESS = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    /// @dev Mapping from pay request UID => whether the pay request is processed.
    mapping(bytes32 => bool) private processed;

    /**
     *  @notice Info of fee payout recipients.
     *
     *  @param clientId ClientId of fee recipient
     *  @param payoutAddress Recipient address
     *  @param feeBPS The fee basis points to be charged. Max = 10000 (10000 = 100%, 1000 = 10%)
     */
    struct PayoutInfo {
        bytes32 clientId;
        address payable payoutAddress;
        uint256 feeBPS;
    }

    /**
     *  @notice The body of a request to purchase tokens.
     *
     *  @param clientId Thirdweb clientId for logging attribution data
     *  @param transactionId Acts as a uid and a key to lookup associated swap provider
     *  @param tokenAddress Address of the currency used for purchase
     *  @param tokenAmount Currency amount being sent
     *  @param expirationTimestamp The unix timestamp at which the request expires
     *  @param payouts Array of Payout struct - containing fee recipients' info
     *  @param forwardAddress Address of swap provider contract
     *  @param data Calldata for swap provider
     */
    struct PayRequest {
        bytes32 clientId;
        bytes32 transactionId;
        address tokenAddress;
        uint256 tokenAmount;
        uint256 expirationTimestamp;
        PayoutInfo[] payouts;
        address payable forwardAddress;
        bytes data;
    }

    /*///////////////////////////////////////////////////////////////
                                Events
    //////////////////////////////////////////////////////////////*/

    event TokenPurchaseInitiated(
        bytes32 indexed clientId,
        address indexed sender,
        bytes32 transactionId,
        address tokenAddress,
        uint256 tokenAmount
    );

    event TokenPurchaseCompleted(
        bytes32 indexed clientId,
        address indexed receiver,
        bytes32 transactionId,
        address tokenAddress,
        uint256 tokenAmount
    );

    event FeePayout(
        bytes32 indexed clientId,
        address indexed sender,
        address payoutAddress,
        address tokenAddress,
        uint256 feeAmount,
        uint256 feeBPS
    );

    /*///////////////////////////////////////////////////////////////
                                Errors
    //////////////////////////////////////////////////////////////*/

    error PaymentsGatewayMismatchedValue(uint256 expected, uint256 actual);
    error PaymentsGatewayInvalidAmount(uint256 amount);
    error PaymentsGatewayVerificationFailed();
    error PaymentsGatewayFailedToForward();
    error PaymentsGatewayRequestExpired(uint256 expirationTimestamp);

    /*///////////////////////////////////////////////////////////////
                                Constructor
    //////////////////////////////////////////////////////////////*/

    constructor(address contractOwner) Ownable(contractOwner) {}

    /*///////////////////////////////////////////////////////////////
                        External / public functions
    //////////////////////////////////////////////////////////////*/

    /// @notice some bridges may refund need a way to get funds back to user
    function withdrawTo(
        address tokenAddress,
        uint256 tokenAmount,
        address payable receiver
    ) public onlyOwner nonReentrant {
        if (_isTokenERC20(tokenAddress)) {
            SafeTransferLib.safeTransferFrom(tokenAddress, address(this), receiver, tokenAmount);
        } else {
            SafeTransferLib.safeTransferETH(receiver, tokenAmount);
        }
    }

    function withdraw(address tokenAddress, uint256 tokenAmount) external onlyOwner nonReentrant {
        withdrawTo(tokenAddress, tokenAmount, payable(msg.sender));
    }

    /**
      @notice 
      The purpose of initiateTokenPurchase is to be the entrypoint for all thirdweb pay swap / bridge
      transactions. This function will allow us to standardize the logging and fee splitting across all providers. 
      
      Requirements:
      1. Verify the parameters are the same parameters sent from thirdweb pay service by requiring a backend signature
      2. Log transfer start allowing us to link onchain and offchain data
      3. distribute the fees to all the payees (thirdweb, developer, swap provider (?))
      4. forward the user funds to the swap provider (forwardAddress)
     */

    function initiateTokenPurchase(PayRequest calldata req, bytes calldata signature) external payable nonReentrant {
        // verify amount
        if (req.tokenAmount == 0) {
            revert PaymentsGatewayInvalidAmount(req.tokenAmount);
        }

        // verify expiration timestamp
        if (req.expirationTimestamp < block.timestamp) {
            revert PaymentsGatewayRequestExpired(req.expirationTimestamp);
        }

        // verify data
        if (!_verifyTransferStart(req, signature)) {
            revert PaymentsGatewayVerificationFailed();
        }

        if (_isTokenNative(req.tokenAddress)) {
            if (msg.value < req.tokenAmount) {
                revert PaymentsGatewayMismatchedValue(req.tokenAmount, msg.value);
            }
        }

        // mark the pay request as processed
        processed[req.transactionId] = true;

        // distribute fees
        uint256 totalFeeAmount = _distributeFees(req.tokenAddress, req.tokenAmount, req.payouts);

        // determine native value to send
        uint256 sendValue = msg.value; // includes bridge fee etc. (if any)
        if (_isTokenNative(req.tokenAddress)) {
            sendValue = msg.value - totalFeeAmount;

            if (sendValue < req.tokenAmount) {
                revert PaymentsGatewayMismatchedValue(sendValue, req.tokenAmount);
            }
        }

        if (_isTokenERC20(req.tokenAddress)) {
            // pull user funds
            SafeTransferLib.safeTransferFrom(req.tokenAddress, msg.sender, address(this), req.tokenAmount);
            SafeTransferLib.safeApprove(req.tokenAddress, req.forwardAddress, req.tokenAmount);
        }

        {
            (bool success, bytes memory response) = req.forwardAddress.call{ value: sendValue }(req.data);
            if (!success) {
                // If there is return data, the delegate call reverted with a reason or a custom error, which we bubble up.
                if (response.length > 0) {
                    assembly {
                        let returndata_size := mload(response)
                        revert(add(32, response), returndata_size)
                    }
                } else {
                    revert PaymentsGatewayFailedToForward();
                }
            }
        }

        emit TokenPurchaseInitiated(req.clientId, msg.sender, req.transactionId, req.tokenAddress, req.tokenAmount);
    }

    /**
      @notice 
      The purpose of completeTokenPurchase is to provide a forwarding contract call
      on the destination chain. For some swap providers, they can only guarantee the toAmount
      if we use a contract call. This allows us to call the endTransfer function and forward the 
      funds to the end user. 

      Requirements:
      1. Log the transfer end
      2. forward the user funds
     */
    function completeTokenPurchase(
        bytes32 clientId,
        bytes32 transactionId,
        address tokenAddress,
        uint256 tokenAmount,
        address payable receiverAddress
    ) external payable nonReentrant {
        if (tokenAmount == 0) {
            revert PaymentsGatewayInvalidAmount(tokenAmount);
        }

        if (_isTokenNative(tokenAddress)) {
            if (msg.value < tokenAmount) {
                revert PaymentsGatewayMismatchedValue(tokenAmount, msg.value);
            }
        }

        // pull user funds
        if (_isTokenERC20(tokenAddress)) {
            SafeTransferLib.safeTransferFrom(tokenAddress, msg.sender, receiverAddress, tokenAmount);
        } else {
            SafeTransferLib.safeTransferETH(receiverAddress, tokenAmount);
        }

        emit TokenPurchaseCompleted(clientId, receiverAddress, transactionId, tokenAddress, tokenAmount);
    }

    /*///////////////////////////////////////////////////////////////
                            Internal functions
    //////////////////////////////////////////////////////////////*/

    function _domainNameAndVersion() internal pure override returns (string memory name, string memory version) {
        name = "PaymentsGateway";
        version = "1";
    }

    function _hashPayoutInfo(PayoutInfo[] calldata payouts) private pure returns (bytes32) {
        bytes32[] memory payoutsHashes = new bytes32[](payouts.length);
        for (uint i = 0; i < payouts.length; i++) {
            payoutsHashes[i] = keccak256(
                abi.encode(PAYOUTINFO_TYPEHASH, payouts[i].clientId, payouts[i].payoutAddress, payouts[i].feeBPS)
            );
        }
        return keccak256(abi.encodePacked(payoutsHashes));
    }

    function _distributeFees(
        address tokenAddress,
        uint256 tokenAmount,
        PayoutInfo[] calldata payouts
    ) private returns (uint256) {
        uint256 totalFeeAmount = 0;

        for (uint32 payeeIdx = 0; payeeIdx < payouts.length; payeeIdx++) {
            uint256 feeAmount = _calculateFee(tokenAmount, payouts[payeeIdx].feeBPS);
            totalFeeAmount += feeAmount;

            emit FeePayout(
                payouts[payeeIdx].clientId,
                msg.sender,
                payouts[payeeIdx].payoutAddress,
                tokenAddress,
                feeAmount,
                payouts[payeeIdx].feeBPS
            );
            if (_isTokenNative(tokenAddress)) {
                SafeTransferLib.safeTransferETH(payouts[payeeIdx].payoutAddress, feeAmount);
            } else {
                SafeTransferLib.safeTransferFrom(tokenAddress, msg.sender, payouts[payeeIdx].payoutAddress, feeAmount);
            }
        }

        if (totalFeeAmount > tokenAmount) {
            revert PaymentsGatewayMismatchedValue(totalFeeAmount, tokenAmount);
        }
        return totalFeeAmount;
    }

    function _verifyTransferStart(PayRequest calldata req, bytes calldata signature) private view returns (bool) {
        bytes32 payoutsHash = _hashPayoutInfo(req.payouts);
        bytes32 structHash = keccak256(
            abi.encode(
                REQUEST_TYPEHASH,
                req.clientId,
                req.transactionId,
                req.tokenAddress,
                req.tokenAmount,
                req.expirationTimestamp,
                payoutsHash,
                req.forwardAddress,
                keccak256(req.data)
            )
        );

        bytes32 digest = _hashTypedData(structHash);
        address recovered = digest.recover(signature);
        bool valid = recovered == owner() && !processed[req.transactionId];

        return valid;
    }

    function _isTokenERC20(address tokenAddress) private pure returns (bool) {
        return tokenAddress != NATIVE_TOKEN_ADDRESS;
    }

    function _isTokenNative(address tokenAddress) private pure returns (bool) {
        return tokenAddress == NATIVE_TOKEN_ADDRESS;
    }

    function _calculateFee(uint256 amount, uint256 feeBPS) private pure returns (uint256) {
        uint256 feeAmount = (amount * feeBPS) / 10_000;
        return feeAmount;
    }
}
