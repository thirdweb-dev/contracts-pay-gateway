// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.22;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Context.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { EIP712 } from "./utils/EIP712.sol";

import { SafeTransferLib } from "./lib/SafeTransferLib.sol";
import { ECDSA } from "./lib/ECDSA.sol";

/**
  Requirements
  - easily change fee / payout structure per transaction
  - easily change provider per transaction

  TODO: 
    - add receiver function
    - add thirdweb signer for tamperproofing
    - add operator role automating withdrawals
 */

contract PaymentsGateway is EIP712, Ownable, ReentrancyGuard {
    using ECDSA for bytes32;

    error PaymentsGatewayInvalidOperator(address operator);
    error PaymentsGatewayNotOwnerOrOperator(address caller);
    error PaymentsGatewayMismatchedValue(uint256 expected, uint256 actual);
    error PaymentsGatewayInvalidAmount(uint256 amount);
    error PaymentsGatewayVerificationFailed();
    error PaymentsGatewayFailedToForward();

    event TransferStart(
        bytes32 indexed clientId,
        address indexed sender,
        bytes32 transactionId,
        address tokenAddress,
        uint256 tokenAmount
    );

    event TransferEnd(
        bytes32 indexed clientId,
        address indexed receiver,
        bytes32 transactionId,
        address tokenAddress,
        uint256 tokenAmount
    );

    /**
    Note: not sure if this is completely necessary
    estimate the gas on this and remove
    we could always combine transferFrom logs w/ this transaction
    where from=Address(this) => to != provider
    */
    event FeePayout(
        bytes32 indexed clientId,
        address indexed sender,
        address payoutAddress,
        address tokenAddress,
        uint256 feeAmount,
        uint256 feeBPS
    );

    event OperatorChanged(address indexed previousOperator, address indexed newOperator);

    struct PayoutInfo {
        bytes32 clientId;
        address payable payoutAddress;
        uint256 feeBPS;
    }
    struct PayRequest {
        bytes32 clientId;
        bytes32 transactionId;
        address tokenAddress;
        uint256 tokenAmount;
        PayoutInfo[] payouts;
        address payable forwardAddress;
        bytes data;
    }

    bytes32 private constant PAYOUTINFO_TYPEHASH =
        keccak256("PayoutInfo(bytes32 clientId,address payoutAddress,uint256 feeBPS)");
    bytes32 private constant REQUEST_TYPEHASH =
        keccak256(
            "PayRequest(bytes32 clientId,bytes32 transactionId,address tokenAddress,uint256 tokenAmount,PayoutInfo[] payouts)PayoutInfo(bytes32 clientId,address payoutAddress,uint256 feeBPS)"
        );
    address private constant THIRDWEB_CLIENT_ID = 0x0000000000000000000000000000000000000000;
    address private constant NATIVE_TOKEN_ADDRESS = 0x0000000000000000000000000000000000000000;
    address private _operator;

    /// @dev Mapping from pay request UID => whether the pay request is processed.
    mapping(bytes32 => bool) private processed;

    constructor(address contractOwner, address initialOperator) Ownable(contractOwner) {
        if (initialOperator == address(0)) {
            revert PaymentsGatewayInvalidOperator(initialOperator);
        }
        _operator = initialOperator;
        emit OperatorChanged(address(0), initialOperator);
    }

    modifier onlyOwnerOrOperator() {
        if (msg.sender != owner() && msg.sender != _operator) {
            revert PaymentsGatewayNotOwnerOrOperator(msg.sender);
        }
        _;
    }

    function setOperator(address newOperator) public onlyOwnerOrOperator {
        if (newOperator == address(0)) {
            revert PaymentsGatewayInvalidOperator(newOperator);
        }
        emit OperatorChanged(_operator, newOperator);
        _operator = newOperator;
    }

    function getOperator() public view returns (address) {
        return _operator;
    }

    /* some bridges may refund need a way to get funds back to user */
    function withdrawTo(
        address tokenAddress,
        uint256 tokenAmount,
        address payable receiver
    ) public onlyOwnerOrOperator nonReentrant {
        if (_isTokenERC20(tokenAddress)) {
            SafeTransferLib.safeTransferFrom(tokenAddress, address(this), receiver, tokenAmount);
        } else {
            SafeTransferLib.safeTransferETH(receiver, tokenAmount);
        }
    }

    function withdraw(address tokenAddress, uint256 tokenAmount) external onlyOwnerOrOperator nonReentrant {
        withdrawTo(tokenAddress, tokenAmount, payable(msg.sender));
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

    function _domainNameAndVersion() internal pure override returns (string memory name, string memory version) {
        name = "PaymentsGateway";
        version = "1";
    }

    function _hashPayoutInfo(PayoutInfo[] calldata payouts) private pure returns (bytes32) {
        bytes32 payoutHash = PAYOUTINFO_TYPEHASH;
        for (uint256 i = 0; i < payouts.length; ++i) {
            payoutHash = keccak256(
                abi.encode(payoutHash, payouts[i].clientId, payouts[i].payoutAddress, payouts[i].feeBPS)
            );
        }
        return payoutHash;
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
                payoutsHash,
                req.forwardAddress,
                req.data
            )
        );

        bytes32 digest = _hashTypedData(structHash);
        address recovered = digest.recover(signature);
        bool valid = recovered == _operator && !processed[req.transactionId];

        return valid;
    }

    /**
      The purpose of startTransfer is to be the entrypoint for all thirdweb pay swap / bridge
      transactions. This function will allow us to standardize the logging and fee splitting across all providers. 
      
      Requirements:
      1. Verify the parameters are the same parameters sent from thirdweb pay service by requiring a backend signature
      2. Log transfer start allowing us to link onchain and offchain data
      3. distribute the fees to all the payees (thirdweb, developer, swap provider??)
      4. forward the user funds to the swap provider (forwardAddress)
     */

    function startTransfer(PayRequest calldata req, bytes calldata signature) external payable nonReentrant {
        // verify amount
        if (req.tokenAmount == 0) {
            revert PaymentsGatewayInvalidAmount(req.tokenAmount);
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

        emit TransferStart(req.clientId, msg.sender, req.transactionId, req.tokenAddress, req.tokenAmount);
    }

    /**
      The purpose of endTransfer is to provide a forwarding contract call
      on the destination chain. For LiFi (swap provider), they can only guarantee the toAmount
      if we use a contract call. This allows us to call the endTransfer function and forward the 
      funds to the end user. 

      Requirements:
      1. Log the transfer end
      2. forward the user funds
     */
    function endTransfer(
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

        emit TransferEnd(clientId, receiverAddress, transactionId, tokenAddress, tokenAmount);
    }
}
