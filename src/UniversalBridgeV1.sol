// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.22;

/// @author thirdweb

import { SafeTransferLib } from "lib/solady/src/utils/SafeTransferLib.sol";
import { ReentrancyGuard } from "lib/solady/src/utils/ReentrancyGuard.sol";
import { Ownable } from "lib/solady/src/auth/Ownable.sol";
import { UUPSUpgradeable } from "lib/solady/src/utils/UUPSUpgradeable.sol";
import { Initializable } from "lib/solady/src/utils/Initializable.sol";

library UniversalBridgeStorage {
    /// @custom:storage-location erc7201:universal.bridge
    bytes32 public constant UNIVERSAL_BRIDGE_STORAGE_POSITION =
        keccak256(abi.encode(uint256(keccak256("tw.universal.bridge")) - 1)) & ~bytes32(uint256(0xff));

    struct Data {
        /// @dev Mapping from pay request UID => whether the pay request is processed.
        mapping(bytes32 => bool) processed;
        /// @dev protocol fee bps, capped at 300 bps (3%)
        uint256 protocolFeeBps;
        /// @dev protocol fee recipient address
        address protocolFeeRecipient;
        /// @dev whether the transfers are paused
        bool isTransferPaused;
    }

    function data() internal pure returns (Data storage data_) {
        bytes32 position = UNIVERSAL_BRIDGE_STORAGE_POSITION;
        assembly {
            data_.slot := position
        }
    }
}

contract UniversalBridgeV1 is Initializable, UUPSUpgradeable, Ownable, ReentrancyGuard {
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

    error UniversalBridgeMismatchedValue(uint256 expected, uint256 actual);
    error UniversalBridgeInvalidAmount(uint256 amount);
    error UniversalBridgeFailedToForward();
    error UniversalBridgeMsgValueNotZero();
    error UniversalBridgeInvalidFeeBps();
    error UniversalBridgeZeroAddress();
    error UniversalBridgeTransferPaused();

    constructor() {
        _disableInitializers();
    }

    function initialize(
        address _owner,
        address payable _protocolFeeRecipient,
        uint256 _protocolFeeBps
    ) external initializer {
        _initializeOwner(_owner);
        _setProtocolFeeInfo(_protocolFeeRecipient, _protocolFeeBps);
    }

    modifier whenNotPaused() {
        if (_universalBridgeStorage().isTransferPaused) {
            revert UniversalBridgeTransferPaused();
        }

        _;
    }

    /*///////////////////////////////////////////////////////////////
                        External / public functions
    //////////////////////////////////////////////////////////////*/

    /// @notice check if transaction id has been used / processed
    function isProcessed(bytes32 transactionId) external view returns (bool) {
        return _universalBridgeStorage().processed[transactionId];
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

    function setProtocolFeeInfo(address payable feeRecipient, uint256 feeBps) external onlyOwner {
        _setProtocolFeeInfo(feeRecipient, feeBps);
    }

    function pauseTransfer(bool _pause) external onlyOwner {
        _universalBridgeStorage().isTransferPaused = _pause;
    }

    function getProtocolFeeInfo() external view returns (address feeRecipient, uint256 feeBps) {
        feeRecipient = _universalBridgeStorage().protocolFeeRecipient;
        feeBps = _universalBridgeStorage().protocolFeeBps;
    }

    function isTransferPaused() external view returns (bool) {
        return _universalBridgeStorage().isTransferPaused;
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
    ) external payable nonReentrant onlyProxy whenNotPaused {
        // verify amount
        if (tokenAmount == 0) {
            revert UniversalBridgeInvalidAmount(tokenAmount);
        }
        uint256 sendValue = msg.value; // includes bridge fee etc. (if any)

        // mark the pay request as processed
        _universalBridgeStorage().processed[transactionId] = true;

        // distribute fees
        uint256 totalFeeAmount = _distributeFees(tokenAddress, tokenAmount, developerFeeRecipient, developerFeeBps);

        // determine native value to send
        if (_isNativeToken(tokenAddress)) {
            sendValue = msg.value - totalFeeAmount;

            if (sendValue < tokenAmount) {
                revert UniversalBridgeMismatchedValue(tokenAmount, sendValue);
            }
        }

        if (directTransfer) {
            if (_isNativeToken(tokenAddress)) {
                _call(forwardAddress, sendValue, "");
            } else {
                if (msg.value != 0) {
                    revert UniversalBridgeMsgValueNotZero();
                }

                SafeTransferLib.safeTransferFrom(tokenAddress, msg.sender, forwardAddress, tokenAmount);
            }
        } else {
            if (!_isNativeToken(tokenAddress)) {
                // pull user funds
                SafeTransferLib.safeTransferFrom(tokenAddress, msg.sender, address(this), tokenAmount);
                SafeTransferLib.safeApprove(tokenAddress, forwardAddress, tokenAmount);
            }

            _call(forwardAddress, sendValue, callData);
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

    function _call(address forwardAddress, uint256 sendValue, bytes memory callData) internal {
        (bool success, bytes memory response) = forwardAddress.call{ value: sendValue }(callData);
        if (!success) {
            // If there is return data, the delegate call reverted with a reason or a custom error, which we bubble up.
            if (response.length > 0) {
                assembly {
                    let returndata_size := mload(response)
                    revert(add(32, response), returndata_size)
                }
            } else {
                revert UniversalBridgeFailedToForward();
            }
        }
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
        address protocolFeeRecipient = _universalBridgeStorage().protocolFeeRecipient;
        uint256 protocolFeeBps = _universalBridgeStorage().protocolFeeBps;

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

    function _setProtocolFeeInfo(address payable feeRecipient, uint256 feeBps) internal {
        if (feeRecipient == address(0)) {
            revert UniversalBridgeZeroAddress();
        }

        if (feeBps > MAX_PROTOCOL_FEE_BPS) {
            revert UniversalBridgeInvalidFeeBps();
        }

        _universalBridgeStorage().protocolFeeRecipient = feeRecipient;
        _universalBridgeStorage().protocolFeeBps = feeBps;
    }

    function _isNativeToken(address tokenAddress) private pure returns (bool) {
        return tokenAddress == NATIVE_TOKEN_ADDRESS;
    }

    function _authorizeUpgrade(address) internal override onlyOwner {}

    function _universalBridgeStorage() internal view returns (UniversalBridgeStorage.Data storage) {
        return UniversalBridgeStorage.data();
    }
}
