// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.22;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Context.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import { SafeTransferLib } from "./lib/SafeTransferLib.sol";

/**
  Requirements
  - easily change fee / payout structure per transaction
  - easily change provider per transaction

  TODO: 
    - add receiver function
    - add thirdweb signer for tamperproofing
    - add operator role automating withdrawals
 */

contract PaymentsGateway is Ownable, ReentrancyGuard {
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

    address private constant THIRDWEB_CLIENT_ID = 0x0000000000000000000000000000000000000000;
    address private constant NATIVE_TOKEN_ADDRESS = 0x0000000000000000000000000000000000000000;
    address private _operator;

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

    function _hashPayoutInfo(PayoutInfo[] calldata payouts) private pure returns (bytes32) {
        bytes32 payoutHash = keccak256(abi.encodePacked("PayoutInfo"));
        for (uint256 i = 0; i < payouts.length; ++i) {
            payoutHash = keccak256(
                abi.encodePacked(payoutHash, payouts[i].clientId, payouts[i].payoutAddress, payouts[i].feeBPS)
            );
        }
        return payoutHash;
    }

    function _verifyTransferStart(
        bytes32 clientId,
        bytes32 transactionId,
        address tokenAddress,
        uint256 tokenAmount,
        PayoutInfo[] calldata payouts,
        address payable forwardAddress,
        bytes calldata data,
        bytes calldata signature
    ) private returns (bool) {
        bytes32 payoutsHash = _hashPayoutInfo(payouts);
        bytes32 hash = keccak256(
            abi.encodePacked(clientId, transactionId, tokenAddress, tokenAmount, payoutsHash, forwardAddress, data)
        );

        bytes32 ethSignedMsgHash = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", hash));

        (address recovered, bool valid) = _recoverSigner(ethSignedMsgHash, signature);

        return valid && recovered == _operator;
    }

    function _recoverSigner(bytes32 ethSignedMsgHash, bytes memory signature) public pure returns (address, bool) {
        bytes32 r;
        bytes32 s;
        uint8 v;

        if (signature.length != 65) {
            return (address(0), false);
        }

        assembly {
            r := mload(add(signature, 0x20))
            s := mload(add(signature, 0x40))
            v := byte(0, mload(add(signature, 0x60)))
        }

        if (v < 27) {
            v += 27;
        }

        address recovered = ecrecover(ethSignedMsgHash, v, r, s);
        bool valid = (recovered != address(0));

        return (recovered, valid);
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
    function startTransfer(
        bytes32 clientId,
        bytes32 transactionId,
        address tokenAddress,
        uint256 tokenAmount,
        PayoutInfo[] calldata payouts,
        address payable forwardAddress,
        bytes calldata data,
        bytes calldata signature
    ) external payable nonReentrant {
        // verify amount
        if (tokenAmount == 0) {
            revert PaymentsGatewayInvalidAmount(tokenAmount);
        }

        // verify data
        if (
            !_verifyTransferStart(
                clientId,
                transactionId,
                tokenAddress,
                tokenAmount,
                payouts,
                forwardAddress,
                data,
                signature
            )
        ) {
            revert PaymentsGatewayVerificationFailed();
        }

        if (_isTokenNative(tokenAddress)) {
            if (msg.value < tokenAmount) {
                revert PaymentsGatewayMismatchedValue(tokenAmount, msg.value);
            }
        }

        // distribute fees
        uint256 totalFeeAmount = _distributeFees(tokenAddress, tokenAmount, payouts);

        // determine native value to send
        uint256 sendValue = msg.value; // includes bridge fee etc. (if any)
        if (_isTokenNative(tokenAddress)) {
            sendValue = msg.value - totalFeeAmount;

            if (sendValue < tokenAmount) {
                revert PaymentsGatewayMismatchedValue(sendValue, tokenAmount);
            }
        }

        if (_isTokenERC20(tokenAddress)) {
            // pull user funds
            SafeTransferLib.safeTransferFrom(tokenAddress, msg.sender, address(this), tokenAmount);
            SafeTransferLib.safeApprove(tokenAddress, forwardAddress, tokenAmount);
        }

        {
            (bool success, bytes memory response) = forwardAddress.call{ value: sendValue }(data);
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

        emit TransferStart(clientId, msg.sender, transactionId, tokenAddress, tokenAmount);
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
