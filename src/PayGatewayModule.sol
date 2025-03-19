// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.22;

/// @author thirdweb

import { SafeTransferLib } from "lib/solady/src/utils/SafeTransferLib.sol";
import { ReentrancyGuard } from "lib/solady/src/utils/ReentrancyGuard.sol";
import { ModularModule } from "lib/modular-contracts/src/ModularModule.sol";
import { Ownable } from "lib/solady/src/auth/Ownable.sol";

struct PayoutInfo {
    address payable payoutAddress;
    uint256 feeBps;
}

library PayGatewayModuleStorage {
    /// @custom:storage-location erc7201:pay.gateway.module
    bytes32 public constant PAY_GATEWAY_EXTENSION_STORAGE_POSITION =
        keccak256(abi.encode(uint256(keccak256("pay.gateway.module")) - 1)) & ~bytes32(uint256(0xff));

    struct Data {
        /// @dev Mapping from pay request UID => whether the pay request is processed.
        mapping(bytes32 => bool) processed;
        mapping(bytes32 => PayoutInfo) feePayoutInfo;
        PayoutInfo ownerFeeInfo;
    }

    function data() internal pure returns (Data storage data_) {
        bytes32 position = PAY_GATEWAY_EXTENSION_STORAGE_POSITION;
        assembly {
            data_.slot := position
        }
    }
}

contract PayGatewayModule is ModularModule, ReentrancyGuard {
    /*///////////////////////////////////////////////////////////////
                        State, constants, structs
    //////////////////////////////////////////////////////////////*/

    uint256 private constant _ADMIN_ROLE = 1 << 2;
    address private constant NATIVE_TOKEN_ADDRESS = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    /*///////////////////////////////////////////////////////////////
                                Events
    //////////////////////////////////////////////////////////////*/

    event TokenPurchaseInitiated(
        bytes32 indexed clientId,
        address indexed sender,
        bytes32 transactionId,
        address tokenAddress,
        uint256 tokenAmount,
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

    /*//////////////////////////////////////////////////////////////
                            EXTENSION CONFIG
    //////////////////////////////////////////////////////////////*/

    /// @notice Returns all implemented callback and fallback functions.
    function getModuleConfig() external pure override returns (ModuleConfig memory config) {
        config.fallbackFunctions = new FallbackFunction[](8);

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
        config.fallbackFunctions[3] = FallbackFunction({ selector: this.isProcessed.selector, permissionBits: 0 });
        config.fallbackFunctions[4] = FallbackFunction({
            selector: this.setOwnerFeeInfo.selector,
            permissionBits: _ADMIN_ROLE
        });
        config.fallbackFunctions[5] = FallbackFunction({
            selector: this.setFeeInfo.selector,
            permissionBits: _ADMIN_ROLE
        });
        config.fallbackFunctions[6] = FallbackFunction({ selector: this.getOwnerFeeInfo.selector, permissionBits: 0 });
        config.fallbackFunctions[7] = FallbackFunction({ selector: this.getFeeInfo.selector, permissionBits: 0 });
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
        if (_isTokenNative(tokenAddress)) {
            SafeTransferLib.safeTransferETH(receiver, tokenAmount);
        } else {
            SafeTransferLib.safeTransfer(tokenAddress, receiver, tokenAmount);
        }
    }

    function withdraw(address tokenAddress, uint256 tokenAmount) external nonReentrant {
        withdrawTo(tokenAddress, tokenAmount, payable(msg.sender));
    }

    function setOwnerFeeInfo(address payable payoutAddress, uint256 feeBps) external {
        PayGatewayModuleStorage.data().ownerFeeInfo = PayoutInfo({ payoutAddress: payoutAddress, feeBps: feeBps });
    }

    function getOwnerFeeInfo() external view returns (address payoutAddress, uint256 feeBps) {
        payoutAddress = PayGatewayModuleStorage.data().ownerFeeInfo.payoutAddress;
        feeBps = PayGatewayModuleStorage.data().ownerFeeInfo.feeBps;
    }

    function setFeeInfo(bytes32 clientId, address payable payoutAddress, uint256 feeBps) external {
        PayGatewayModuleStorage.data().feePayoutInfo[clientId] = PayoutInfo({
            payoutAddress: payoutAddress,
            feeBps: feeBps
        });
    }

    function getFeeInfo(bytes32 clientId) external view returns (address payoutAddress, uint256 feeBps) {
        payoutAddress = PayGatewayModuleStorage.data().feePayoutInfo[clientId].payoutAddress;
        feeBps = PayGatewayModuleStorage.data().feePayoutInfo[clientId].feeBps;
    }

    /**
      @notice 
      The purpose of initiateTokenPurchase is to be the entrypoint for all thirdweb pay swap / bridge
      transactions. This function will allow us to standardize the logging and fee splitting across all providers. 
     */
    function initiateTokenPurchase(
        bytes32 clientId,
        bytes32 transactionId,
        address tokenAddress,
        uint256 tokenAmount,
        address payable forwardAddress,
        bool directTransfer,
        bytes calldata callData,
        bytes calldata extraData
    ) external payable nonReentrant {
        // verify amount
        if (tokenAmount == 0) {
            revert PayGatewayInvalidAmount(tokenAmount);
        }
        uint256 sendValue = msg.value; // includes bridge fee etc. (if any)

        // mark the pay request as processed
        PayGatewayModuleStorage.data().processed[transactionId] = true;

        // distribute fees
        uint256 totalFeeAmount = _distributeFees(tokenAddress, tokenAmount, clientId);

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

        emit TokenPurchaseInitiated(clientId, msg.sender, transactionId, tokenAddress, tokenAmount, extraData);
    }

    /*///////////////////////////////////////////////////////////////
                            Internal functions
    //////////////////////////////////////////////////////////////*/

    function _distributeFees(address tokenAddress, uint256 tokenAmount, bytes32 clientId) private returns (uint256) {
        PayoutInfo memory devFeeInfo = PayGatewayModuleStorage.data().feePayoutInfo[clientId];
        PayoutInfo memory ownerFeeInfo = PayGatewayModuleStorage.data().ownerFeeInfo;

        uint256 ownerFee = (tokenAmount * ownerFeeInfo.feeBps) / 10_000;

        uint256 devFee = (tokenAmount * devFeeInfo.feeBps) / 10_000;

        uint256 totalFeeAmount = ownerFee + devFee;

        if (_isTokenNative(tokenAddress)) {
            if (ownerFee != 0) {
                SafeTransferLib.safeTransferETH(ownerFeeInfo.payoutAddress, ownerFee);
            }

            if (devFee != 0) {
                SafeTransferLib.safeTransferETH(devFeeInfo.payoutAddress, devFee);
            }
        } else {
            if (ownerFee != 0) {
                SafeTransferLib.safeTransferFrom(tokenAddress, msg.sender, ownerFeeInfo.payoutAddress, ownerFee);
            }

            if (devFee != 0) {
                SafeTransferLib.safeTransferFrom(tokenAddress, msg.sender, devFeeInfo.payoutAddress, devFee);
            }
        }

        return totalFeeAmount;
    }

    function _isTokenNative(address tokenAddress) private pure returns (bool) {
        return tokenAddress == NATIVE_TOKEN_ADDRESS;
    }
}
