// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.22;

/// @author thirdweb

import { EIP712 } from "lib/solady/src/utils/EIP712.sol";
import { SafeTransferLib } from "lib/solady/src/utils/SafeTransferLib.sol";
import { ReentrancyGuard } from "lib/solady/src/utils/ReentrancyGuard.sol";
import { ECDSA } from "lib/solady/src/utils/ECDSA.sol";
import { ModularModule } from "lib/modular-contracts/src/ModularModule.sol";
import { Ownable } from "lib/solady/src/auth/Ownable.sol";

library PayGatewayModuleStorage {
    /// @custom:storage-location erc7201:pay.gateway.module
    bytes32 public constant PAY_GATEWAY_EXTENSION_STORAGE_POSITION =
        keccak256(abi.encode(uint256(keccak256("pay.gateway.module")) - 1)) & ~bytes32(uint256(0xff));

    struct Data {
        /// @dev Mapping from pay request UID => whether the pay request is processed.
        mapping(bytes32 => bool) processed;
    }

    function data() internal pure returns (Data storage data_) {
        bytes32 position = PAY_GATEWAY_EXTENSION_STORAGE_POSITION;
        assembly {
            data_.slot := position
        }
    }
}

contract PayGatewayModule is EIP712, ModularModule, ReentrancyGuard {
    using ECDSA for bytes32;

    /*///////////////////////////////////////////////////////////////
                        State, constants, structs
    //////////////////////////////////////////////////////////////*/

    uint256 private constant _ADMIN_ROLE = 1 << 2;

    bytes32 private constant PAYOUTINFO_TYPEHASH =
        keccak256("PayoutInfo(bytes32 clientId,address payoutAddress,uint256 feeAmount)");
    bytes32 private constant REQUEST_TYPEHASH =
        keccak256(
            "PayRequest(bytes32 clientId,bytes32 transactionId,address tokenAddress,uint256 tokenAmount,uint256 expirationTimestamp,PayoutInfo[] payouts,address forwardAddress,bool directTransfer,bytes data)PayoutInfo(bytes32 clientId,address payoutAddress,uint256 feeAmount)"
        );
    address private constant NATIVE_TOKEN_ADDRESS = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    /**
     *  @notice Info of fee payout recipients.
     *
     *  @param clientId ClientId of fee recipient
     *  @param payoutAddress Recipient address
     *  @param feeAmount The fee amount to be paid to each recipient
     */
    struct PayoutInfo {
        bytes32 clientId;
        address payable payoutAddress;
        uint256 feeAmount;
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
     *  @param directTransfer Whether the payment is a direct transfer to another address
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
        bool directTransfer;
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
        uint256 feeAmount
    );

    /*///////////////////////////////////////////////////////////////
                                Errors
    //////////////////////////////////////////////////////////////*/

    error PayGatewayMismatchedValue(uint256 expected, uint256 actual);
    error PayGatewayInvalidAmount(uint256 amount);
    error PayGatewayVerificationFailed();
    error PayGatewayFailedToForward();
    error PayGatewayRequestExpired(uint256 expirationTimestamp);
    error PayGatewayMsgValueNotZero();

    /*//////////////////////////////////////////////////////////////
                            EXTENSION CONFIG
    //////////////////////////////////////////////////////////////*/

    /// @notice Returns all implemented callback and fallback functions.
    function getModuleConfig() external pure override returns (ModuleConfig memory config) {
        config.fallbackFunctions = new FallbackFunction[](6);

        config.fallbackFunctions[0] = FallbackFunction({
            selector: this.withdrawTo.selector,
            permissionBits: _ADMIN_ROLE
        });
        config.fallbackFunctions[1] = FallbackFunction({
            selector: this.withdraw.selector,
            permissionBits: _ADMIN_ROLE
        });
        config.fallbackFunctions[2] = FallbackFunction({
            selector: this.initiateTokenPurchase.selector,
            permissionBits: 0
        });
        config.fallbackFunctions[3] = FallbackFunction({
            selector: this.completeTokenPurchase.selector,
            permissionBits: 0
        });
        config.fallbackFunctions[4] = FallbackFunction({ selector: this.eip712Domain.selector, permissionBits: 0 });
        config.fallbackFunctions[5] = FallbackFunction({ selector: this.isProcessed.selector, permissionBits: 0 });
    }

    /*///////////////////////////////////////////////////////////////
                        External / public functions
    //////////////////////////////////////////////////////////////*/

    /// @notice check if transaction id has been used / processed
    function isProcessed(bytes32 transactionId) external view returns (bool) {
        return PayGatewayModuleStorage.data().processed[transactionId];
    }

    /// @notice some bridges may refund need a way to get funds back to user
    function withdrawTo(address tokenAddress, uint256 tokenAmount, address payable receiver) public nonReentrant {
        if (_isTokenERC20(tokenAddress)) {
            SafeTransferLib.safeTransfer(tokenAddress, receiver, tokenAmount);
        } else {
            SafeTransferLib.safeTransferETH(receiver, tokenAmount);
        }
    }

    function withdraw(address tokenAddress, uint256 tokenAmount) external nonReentrant {
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
            revert PayGatewayInvalidAmount(req.tokenAmount);
        }

        // verify expiration timestamp
        if (req.expirationTimestamp < block.timestamp) {
            revert PayGatewayRequestExpired(req.expirationTimestamp);
        }

        // verify data
        if (!_verifyTransferStart(req, signature)) {
            revert PayGatewayVerificationFailed();
        }

        // mark the pay request as processed
        PayGatewayModuleStorage.data().processed[req.transactionId] = true;

        // distribute fees
        uint256 totalFeeAmount = _distributeFees(req.tokenAddress, req.payouts);

        // determine native value to send
        uint256 sendValue = msg.value; // includes bridge fee etc. (if any)
        if (_isTokenNative(req.tokenAddress)) {
            sendValue = msg.value - totalFeeAmount;

            if (sendValue < req.tokenAmount) {
                revert PayGatewayMismatchedValue(req.tokenAmount, sendValue);
            }
        }

        if (req.directTransfer) {
            if (_isTokenNative(req.tokenAddress)) {
                (bool success, bytes memory response) = req.forwardAddress.call{ value: sendValue }("");

                if (!success) {
                    // If there is return data, the delegate call reverted with a reason or a custom error, which we bubble up.
                    if (response.length > 0) {
                        assembly {
                            let returndata_size := mload(response)
                            revert(add(32, response), returndata_size)
                        }
                    } else {
                        revert PayGatewayFailedToForward();
                    }
                }
            } else {
                if (msg.value != 0) {
                    revert PayGatewayMsgValueNotZero();
                }

                SafeTransferLib.safeTransferFrom(req.tokenAddress, msg.sender, req.forwardAddress, req.tokenAmount);
            }
        } else {
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
                        revert PayGatewayFailedToForward();
                    }
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
            revert PayGatewayInvalidAmount(tokenAmount);
        }

        if (_isTokenNative(tokenAddress)) {
            if (msg.value != tokenAmount) {
                revert PayGatewayMismatchedValue(tokenAmount, msg.value);
            }
        }

        // pull user funds
        if (_isTokenERC20(tokenAddress)) {
            if (msg.value != 0) {
                revert PayGatewayMsgValueNotZero();
            }

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
        name = "PayGateway";
        version = "1";
    }

    function _hashPayoutInfo(PayoutInfo[] calldata payouts) private pure returns (bytes32) {
        bytes32[] memory payoutsHashes = new bytes32[](payouts.length);
        for (uint i = 0; i < payouts.length; i++) {
            payoutsHashes[i] = keccak256(
                abi.encode(PAYOUTINFO_TYPEHASH, payouts[i].clientId, payouts[i].payoutAddress, payouts[i].feeAmount)
            );
        }
        return keccak256(abi.encodePacked(payoutsHashes));
    }

    function _distributeFees(address tokenAddress, PayoutInfo[] calldata payouts) private returns (uint256) {
        uint256 totalFeeAmount = 0;

        for (uint32 payeeIdx = 0; payeeIdx < payouts.length; payeeIdx++) {
            totalFeeAmount += payouts[payeeIdx].feeAmount;

            emit FeePayout(
                payouts[payeeIdx].clientId,
                msg.sender,
                payouts[payeeIdx].payoutAddress,
                tokenAddress,
                payouts[payeeIdx].feeAmount
            );
            if (_isTokenNative(tokenAddress)) {
                SafeTransferLib.safeTransferETH(payouts[payeeIdx].payoutAddress, payouts[payeeIdx].feeAmount);
            } else {
                SafeTransferLib.safeTransferFrom(
                    tokenAddress,
                    msg.sender,
                    payouts[payeeIdx].payoutAddress,
                    payouts[payeeIdx].feeAmount
                );
            }
        }

        return totalFeeAmount;
    }

    function _verifyTransferStart(PayRequest calldata req, bytes calldata signature) private view returns (bool) {
        bool processed = PayGatewayModuleStorage.data().processed[req.transactionId];

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
                req.directTransfer,
                keccak256(req.data)
            )
        );

        bytes32 digest = _hashTypedData(structHash);
        address recovered = digest.recover(signature);
        bool valid = recovered == Ownable(address(this)).owner() && !processed;

        return valid;
    }

    function _isTokenERC20(address tokenAddress) private pure returns (bool) {
        return tokenAddress != NATIVE_TOKEN_ADDRESS;
    }

    function _isTokenNative(address tokenAddress) private pure returns (bool) {
        return tokenAddress == NATIVE_TOKEN_ADDRESS;
    }
}
