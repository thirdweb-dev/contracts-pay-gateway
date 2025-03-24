// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.22;

/// @author thirdweb

import { SafeTransferLib } from "lib/solady/src/utils/SafeTransferLib.sol";
import { ReentrancyGuard } from "lib/solady/src/utils/ReentrancyGuard.sol";
import { Ownable } from "lib/solady/src/auth/Ownable.sol";
import { UUPSUpgradeable } from "lib/solady/src/utils/UUPSUpgradeable.sol";
import { Initializable } from "lib/solady/src/utils/Initializable.sol";

struct PayoutInfo {
    address payable payoutAddress;
    uint256 feeBps;
}

library PayGatewayImplementationStorage {
    /// @custom:storage-location erc7201:pay.gateway.implementation
    bytes32 public constant PAY_GATEWAY_IMPLEMENTATION_STORAGE_POSITION =
        keccak256(abi.encode(uint256(keccak256("pay.gateway.implementation")) - 1)) & ~bytes32(uint256(0xff));

    struct Data {
        /// @dev Mapping from pay request UID => whether the pay request is processed.
        mapping(bytes32 => bool) processed;
        PayoutInfo protocolFeeInfo;
    }

    function data() internal pure returns (Data storage data_) {
        bytes32 position = PAY_GATEWAY_IMPLEMENTATION_STORAGE_POSITION;
        assembly {
            data_.slot := position
        }
    }
}

contract PayGatewayImplementation is Initializable, UUPSUpgradeable, Ownable, ReentrancyGuard {
    /*///////////////////////////////////////////////////////////////
                        State, constants, structs
    //////////////////////////////////////////////////////////////*/

    address private constant NATIVE_TOKEN_ADDRESS = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    /*///////////////////////////////////////////////////////////////
                                Events
    //////////////////////////////////////////////////////////////*/

    event TransactionInitiated(
        address indexed sender,
        bytes32 indexed transactionId,
        address tokenAddress,
        uint256 tokenAmount,
        address payoutAddress,
        uint256 feeBps,
        bytes extraData
    );

    /*///////////////////////////////////////////////////////////////
                                Errors
    //////////////////////////////////////////////////////////////*/

    error PayGatewayMismatchedValue(uint256 expected, uint256 actual);
    error PayGatewayInvalidAmount(uint256 amount);
    error PayGatewayFailedToForward();
    error PayGatewayMsgValueNotZero();
    error PayGatewayInvalidFeeBps();

    constructor() {
        _disableInitializers();
    }

    function initialize(address _defaultAdmin, address payable _payoutAddress, uint256 _feeBps) external initializer {
        _initializeOwner(_defaultAdmin);
        _setProtocolFeeInfo(_payoutAddress, _feeBps);
    }

    /*///////////////////////////////////////////////////////////////
                        External / public functions
    //////////////////////////////////////////////////////////////*/

    /// @notice check if transaction id has been used / processed
    function isProcessed(bytes32 transactionId) external view returns (bool) {
        return PayGatewayImplementationStorage.data().processed[transactionId];
    }

    /// @notice some bridges may refund need a way to get funds back to user
    function withdrawTo(
        address tokenAddress,
        uint256 tokenAmount,
        address payable receiver
    ) public nonReentrant onlyOwner {
        if (_isTokenNative(tokenAddress)) {
            SafeTransferLib.safeTransferETH(receiver, tokenAmount);
        } else {
            SafeTransferLib.safeTransfer(tokenAddress, receiver, tokenAmount);
        }
    }

    function withdraw(address tokenAddress, uint256 tokenAmount) external nonReentrant onlyOwner {
        withdrawTo(tokenAddress, tokenAmount, payable(msg.sender));
    }

    function setProtocolFeeInfo(address payable payoutAddress, uint256 feeBps) external onlyOwner {
        _setProtocolFeeInfo(payoutAddress, feeBps);
    }

    function _setProtocolFeeInfo(address payable payoutAddress, uint256 feeBps) internal {
        PayGatewayImplementationStorage.data().protocolFeeInfo = PayoutInfo({
            payoutAddress: payoutAddress,
            feeBps: feeBps
        });
    }

    function getOwnerFeeInfo() external view returns (address payoutAddress, uint256 feeBps) {
        payoutAddress = PayGatewayImplementationStorage.data().protocolFeeInfo.payoutAddress;
        feeBps = PayGatewayImplementationStorage.data().protocolFeeInfo.feeBps;
    }

    /**
      @notice
      The purpose of initiateTransaction is to be the entrypoint for all thirdweb pay swap / bridge
      transactions. This function will allow us to standardize the logging and fee splitting across all providers.
     */
    function initiateTransaction(
        bytes32 transactionId,
        address tokenAddress,
        uint256 tokenAmount,
        address payable forwardAddress,
        address payable payoutAddress,
        uint256 feeBps,
        bool directTransfer,
        bytes calldata callData,
        bytes calldata extraData
    ) external payable nonReentrant onlyProxy {
        // verify amount
        if (tokenAmount == 0) {
            revert PayGatewayInvalidAmount(tokenAmount);
        }
        uint256 sendValue = msg.value; // includes bridge fee etc. (if any)

        // mark the pay request as processed
        PayGatewayImplementationStorage.data().processed[transactionId] = true;

        // distribute fees
        uint256 totalFeeAmount = _distributeFees(tokenAddress, tokenAmount, payoutAddress, feeBps);

        // determine native value to send
        if (_isTokenNative(tokenAddress)) {
            sendValue = msg.value - totalFeeAmount;

            if (sendValue < tokenAmount) {
                revert PayGatewayMismatchedValue(tokenAmount, sendValue);
            }
        }

        if (directTransfer) {
            if (_isTokenNative(tokenAddress)) {
                (bool success, bytes memory response) = forwardAddress.call{ value: sendValue }("");

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

                SafeTransferLib.safeTransferFrom(tokenAddress, msg.sender, forwardAddress, tokenAmount);
            }
        } else {
            if (!_isTokenNative(tokenAddress)) {
                // pull user funds
                SafeTransferLib.safeTransferFrom(tokenAddress, msg.sender, address(this), tokenAmount);
                SafeTransferLib.safeApprove(tokenAddress, forwardAddress, tokenAmount);
            }

            {
                (bool success, bytes memory response) = forwardAddress.call{ value: sendValue }(callData);
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

        emit TransactionInitiated(
            msg.sender,
            transactionId,
            tokenAddress,
            tokenAmount,
            payoutAddress,
            feeBps,
            extraData
        );
    }

    /*///////////////////////////////////////////////////////////////
                            Internal functions
    //////////////////////////////////////////////////////////////*/

    function _distributeFees(
        address tokenAddress,
        uint256 tokenAmount,
        address payoutAddress,
        uint256 feeBps
    ) private returns (uint256) {
        PayoutInfo memory protocolFeeInfo = PayGatewayImplementationStorage.data().protocolFeeInfo;

        uint256 protocolFee = (tokenAmount * protocolFeeInfo.feeBps) / 10_000;

        uint256 devFee = (tokenAmount * feeBps) / 10_000;

        uint256 totalFeeAmount = protocolFee + devFee;

        if (_isTokenNative(tokenAddress)) {
            if (protocolFee != 0) {
                SafeTransferLib.safeTransferETH(protocolFeeInfo.payoutAddress, protocolFee);
            }

            if (devFee != 0) {
                SafeTransferLib.safeTransferETH(payoutAddress, devFee);
            }
        } else {
            if (protocolFee != 0) {
                SafeTransferLib.safeTransferFrom(tokenAddress, msg.sender, protocolFeeInfo.payoutAddress, protocolFee);
            }

            if (devFee != 0) {
                SafeTransferLib.safeTransferFrom(tokenAddress, msg.sender, payoutAddress, devFee);
            }
        }

        return totalFeeAmount;
    }

    function _isTokenNative(address tokenAddress) private pure returns (bool) {
        return tokenAddress == NATIVE_TOKEN_ADDRESS;
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}
}
