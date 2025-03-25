// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.22;

/// @author thirdweb

import { SafeTransferLib } from "lib/solady/src/utils/SafeTransferLib.sol";
import { ReentrancyGuard } from "lib/solady/src/utils/ReentrancyGuard.sol";
import { Ownable } from "lib/solady/src/auth/Ownable.sol";
import { UUPSUpgradeable } from "lib/solady/src/utils/UUPSUpgradeable.sol";
import { Initializable } from "lib/solady/src/utils/Initializable.sol";

library UniversalGatewayV1Storage {
    /// @custom:storage-location erc7201:universal.gateway.v1
    bytes32 public constant UNIVERSAL_GATEWAY_V1_STORAGE_POSITION =
        keccak256(abi.encode(uint256(keccak256("universal.gateway.v1")) - 1)) & ~bytes32(uint256(0xff));

    struct Data {
        /// @dev Mapping from pay request UID => whether the pay request is processed.
        mapping(bytes32 => bool) processed;
        /// @dev protocol fee bps, capped at 300 bps (3%)
        uint256 protocolFeeBps;
        /// @dev protocol fee recipient address
        address protocolFeeRecipient;
    }

    function data() internal pure returns (Data storage data_) {
        bytes32 position = UNIVERSAL_GATEWAY_V1_STORAGE_POSITION;
        assembly {
            data_.slot := position
        }
    }
}

contract UniversalGatewayV1 is Initializable, UUPSUpgradeable, Ownable, ReentrancyGuard {
    /*///////////////////////////////////////////////////////////////
                        State, constants, structs
    //////////////////////////////////////////////////////////////*/

    address private constant NATIVE_TOKEN_ADDRESS = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
    uint256 private constant MAX_PROTOCOL_FEE_BPS = 300; // 3%

    /*///////////////////////////////////////////////////////////////
                                Events
    //////////////////////////////////////////////////////////////*/

    event TransactionInitiated(
        address indexed sender,
        bytes32 indexed transactionId,
        address tokenAddress,
        uint256 tokenAmount,
        address developerFeeRecipient,
        uint256 developerFeeBps,
        bytes extraData
    );

    /*///////////////////////////////////////////////////////////////
                                Errors
    //////////////////////////////////////////////////////////////*/

    error UniversalGatewayMismatchedValue(uint256 expected, uint256 actual);
    error UniversalGatewayInvalidAmount(uint256 amount);
    error UniversalGatewayFailedToForward();
    error UniversalGatewayMsgValueNotZero();
    error UniversalGatewayInvalidFeeBps();
    error UniversalGatewayZeroAddress();

    constructor() {
        _disableInitializers();
    }

    function initialize(
        address _defaultAdmin,
        address payable _protocolFeeRecipient,
        uint256 _protocolFeeBps
    ) external initializer {
        _initializeOwner(_defaultAdmin);
        _setProtocolFeeInfo(_protocolFeeRecipient, _protocolFeeBps);
    }

    /*///////////////////////////////////////////////////////////////
                        External / public functions
    //////////////////////////////////////////////////////////////*/

    /// @notice check if transaction id has been used / processed
    function isProcessed(bytes32 transactionId) external view returns (bool) {
        return _universalGatewayV1Storage().processed[transactionId];
    }

    /// @notice some bridges may refund need a way to get funds back to user
    function withdrawTo(
        address tokenAddress,
        uint256 tokenAmount,
        address payable receiver
    ) public nonReentrant onlyOwner {
        if (_isNativeToken(tokenAddress)) {
            SafeTransferLib.safeTransferETH(receiver, tokenAmount);
        } else {
            SafeTransferLib.safeTransfer(tokenAddress, receiver, tokenAmount);
        }
    }

    function withdraw(address tokenAddress, uint256 tokenAmount) external nonReentrant onlyOwner {
        withdrawTo(tokenAddress, tokenAmount, payable(msg.sender));
    }

    function setProtocolFeeInfo(address payable feeRecipient, uint256 feeBps) external onlyOwner {
        _setProtocolFeeInfo(feeRecipient, feeBps);
    }

    function _setProtocolFeeInfo(address payable feeRecipient, uint256 feeBps) internal {
        if (feeRecipient == address(0)) {
            revert UniversalGatewayZeroAddress();
        }

        if (feeBps > MAX_PROTOCOL_FEE_BPS) {
            revert UniversalGatewayInvalidFeeBps();
        }

        _universalGatewayV1Storage().protocolFeeRecipient = feeRecipient;
        _universalGatewayV1Storage().protocolFeeBps = feeBps;
    }

    function getProtocolFeeInfo() external view returns (address feeRecipient, uint256 feeBps) {
        feeRecipient = _universalGatewayV1Storage().protocolFeeRecipient;
        feeBps = _universalGatewayV1Storage().protocolFeeBps;
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
        address payable developerFeeRecipient,
        uint256 developerFeeBps,
        bool directTransfer,
        bytes calldata callData,
        bytes calldata extraData
    ) external payable nonReentrant onlyProxy {
        // verify amount
        if (tokenAmount == 0) {
            revert UniversalGatewayInvalidAmount(tokenAmount);
        }
        uint256 sendValue = msg.value; // includes bridge fee etc. (if any)

        // mark the pay request as processed
        _universalGatewayV1Storage().processed[transactionId] = true;

        // distribute fees
        uint256 totalFeeAmount = _distributeFees(tokenAddress, tokenAmount, developerFeeRecipient, developerFeeBps);

        // determine native value to send
        if (_isNativeToken(tokenAddress)) {
            sendValue = msg.value - totalFeeAmount;

            if (sendValue < tokenAmount) {
                revert UniversalGatewayMismatchedValue(tokenAmount, sendValue);
            }
        }

        if (directTransfer) {
            if (_isNativeToken(tokenAddress)) {
                (bool success, bytes memory response) = forwardAddress.call{ value: sendValue }("");

                if (!success) {
                    // If there is return data, the delegate call reverted with a reason or a custom error, which we bubble up.
                    if (response.length > 0) {
                        assembly {
                            let returndata_size := mload(response)
                            revert(add(32, response), returndata_size)
                        }
                    } else {
                        revert UniversalGatewayFailedToForward();
                    }
                }
            } else {
                if (msg.value != 0) {
                    revert UniversalGatewayMsgValueNotZero();
                }

                SafeTransferLib.safeTransferFrom(tokenAddress, msg.sender, forwardAddress, tokenAmount);
            }
        } else {
            if (!_isNativeToken(tokenAddress)) {
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
                        revert UniversalGatewayFailedToForward();
                    }
                }
            }
        }

        emit TransactionInitiated(
            msg.sender,
            transactionId,
            tokenAddress,
            tokenAmount,
            developerFeeRecipient,
            developerFeeBps,
            extraData
        );
    }

    /*///////////////////////////////////////////////////////////////
                            Internal functions
    //////////////////////////////////////////////////////////////*/

    function _distributeFees(
        address tokenAddress,
        uint256 tokenAmount,
        address developerFeeRecipient,
        uint256 developerFeeBps
    ) private returns (uint256) {
        address protocolFeeRecipient = _universalGatewayV1Storage().protocolFeeRecipient;
        uint256 protocolFeeBps = _universalGatewayV1Storage().protocolFeeBps;

        uint256 protocolFee = (tokenAmount * protocolFeeBps) / 10_000;
        uint256 developerFee = (tokenAmount * developerFeeBps) / 10_000;
        uint256 totalFeeAmount = protocolFee + developerFee;

        if (_isNativeToken(tokenAddress)) {
            if (protocolFee != 0) {
                SafeTransferLib.safeTransferETH(protocolFeeRecipient, protocolFee);
            }

            if (developerFee != 0) {
                SafeTransferLib.safeTransferETH(developerFeeRecipient, developerFee);
            }
        } else {
            if (protocolFee != 0) {
                SafeTransferLib.safeTransferFrom(tokenAddress, msg.sender, protocolFeeRecipient, protocolFee);
            }

            if (developerFee != 0) {
                SafeTransferLib.safeTransferFrom(tokenAddress, msg.sender, developerFeeRecipient, developerFee);
            }
        }

        return totalFeeAmount;
    }

    function _isNativeToken(address tokenAddress) private pure returns (bool) {
        return tokenAddress == NATIVE_TOKEN_ADDRESS;
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}

    function _universalGatewayV1Storage() internal view returns (UniversalGatewayV1Storage.Data storage) {
        return UniversalGatewayV1Storage.data();
    }
}
