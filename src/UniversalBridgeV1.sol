// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.22;

/// @author thirdweb

import { EIP712 } from "lib/solady/src/utils/EIP712.sol";
import { SafeTransferLib } from "lib/solady/src/utils/SafeTransferLib.sol";
import { ReentrancyGuard } from "lib/solady/src/utils/ReentrancyGuard.sol";
import { ECDSA } from "lib/solady/src/utils/ECDSA.sol";
import { OwnableRoles } from "lib/solady/src/auth/OwnableRoles.sol";
import { UUPSUpgradeable } from "lib/solady/src/utils/UUPSUpgradeable.sol";
import { Initializable } from "lib/solady/src/utils/Initializable.sol";

library UniversalBridgeStorage {
    /// @custom:storage-location erc7201:universal.bridge
    bytes32 public constant UNIVERSAL_BRIDGE_STORAGE_POSITION =
        keccak256(abi.encode(uint256(keccak256("tw.universal.bridge")) - 1)) & ~bytes32(uint256(0xff));

    struct Data {
        /// @dev Mapping from pay request UID => whether the pay request is processed.
        mapping(bytes32 => bool) processed;
        /// @dev Mapping from forward address or token address => whether restricted.
        mapping(address => bool) isRestricted;
        /// @dev protocol fee bps, capped at 300 bps (3%)
        uint256 protocolFeeBps;
        /// @dev protocol fee recipient address
        address protocolFeeRecipient;
        /// @dev whether the bridge is paused
        bool isPaused;
    }

    function data() internal pure returns (Data storage data_) {
        bytes32 position = UNIVERSAL_BRIDGE_STORAGE_POSITION;
        assembly {
            data_.slot := position
        }
    }
}

contract UniversalBridgeV1 is EIP712, Initializable, UUPSUpgradeable, OwnableRoles, ReentrancyGuard {
    using ECDSA for bytes32;

    /*///////////////////////////////////////////////////////////////
                        State, constants, structs
    //////////////////////////////////////////////////////////////*/

    address private constant NATIVE_TOKEN_ADDRESS = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;
    uint256 private constant MAX_PROTOCOL_FEE_BPS = 300; // 3%
    uint256 private constant _OPERATOR_ROLE = 1 << 0;

    struct TransactionRequest {
        bytes32 transactionId;
        address tokenAddress;
        uint256 tokenAmount;
        address payable forwardAddress;
        address payable spenderAddress;
        uint256 expirationTimestamp;
        address payable developerFeeRecipient;
        uint256 developerFeeBps;
        bytes callData;
        bytes extraData;
    }

    bytes32 private constant TRANSACTION_REQUEST_TYPEHASH =
        keccak256(
            "TransactionRequest(bytes32 transactionId,address tokenAddress,uint256 tokenAmount,address forwardAddress,address spenderAddress,uint256 expirationTimestamp,address developerFeeRecipient,uint256 developerFeeBps,bytes callData,bytes extraData)"
        );

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
    error UniversalBridgePaused();
    error UniversalBridgeRestrictedAddress();
    error UniversalBridgeVerificationFailed();
    error UniversalBridgeRequestExpired(uint256 expirationTimestamp);
    error UniversalBridgeTransactionAlreadyProcessed();

    constructor() {
        _disableInitializers();
    }

    function initialize(
        address _owner,
        address _operator,
        address payable _protocolFeeRecipient,
        uint256 _protocolFeeBps
    ) external initializer {
        _initializeOwner(_owner);
        _grantRoles(_operator, _OPERATOR_ROLE);
        _setProtocolFeeInfo(_protocolFeeRecipient, _protocolFeeBps);
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

    function pause(bool _pause) external onlyOwner {
        _universalBridgeStorage().isPaused = _pause;
    }

    function restrictAddress(address _target, bool _restrict) external onlyOwner {
        _universalBridgeStorage().isRestricted[_target] = _restrict;
    }

    function getProtocolFeeInfo() external view returns (address feeRecipient, uint256 feeBps) {
        feeRecipient = _universalBridgeStorage().protocolFeeRecipient;
        feeBps = _universalBridgeStorage().protocolFeeBps;
    }

    function isPaused() external view returns (bool) {
        return _universalBridgeStorage().isPaused;
    }

    function isRestricted(address _target) external view returns (bool) {
        return _universalBridgeStorage().isRestricted[_target];
    }

    /**
      @notice
      The purpose of initiateTransaction is to be the entrypoint for all thirdweb pay swap / bridge
      transactions. This function will allow us to standardize the logging and fee splitting across all providers.
     */
    function initiateTransaction(
        TransactionRequest calldata req,
        bytes calldata signature
    ) external payable nonReentrant onlyProxy {
        // verify req
        if (!_verifyTransactionReq(req, signature)) {
            revert UniversalBridgeVerificationFailed();
        }
        // mark the pay request as processed
        _universalBridgeStorage().processed[req.transactionId] = true;

        if (_universalBridgeStorage().isPaused) {
            revert UniversalBridgePaused();
        }

        if (
            _universalBridgeStorage().isRestricted[req.forwardAddress] ||
            _universalBridgeStorage().isRestricted[req.tokenAddress]
        ) {
            revert UniversalBridgeRestrictedAddress();
        }

        // verify amount
        if (req.tokenAmount == 0) {
            revert UniversalBridgeInvalidAmount(req.tokenAmount);
        }

        uint256 sendValue = msg.value; // includes bridge fee etc. (if any)

        // distribute fees
        uint256 totalFeeAmount = _distributeFees(
            req.tokenAddress,
            req.tokenAmount,
            req.developerFeeRecipient,
            req.developerFeeBps
        );

        if (_isNativeToken(req.tokenAddress)) {
            sendValue = msg.value - totalFeeAmount;

            if (sendValue < req.tokenAmount) {
                revert UniversalBridgeMismatchedValue(req.tokenAmount, sendValue);
            }
            _call(req.forwardAddress, sendValue, req.callData); // calldata empty for direct transfer
        } else if (req.callData.length == 0) {
            if (msg.value != 0) {
                revert UniversalBridgeMsgValueNotZero();
            }
            SafeTransferLib.safeTransferFrom(req.tokenAddress, msg.sender, req.forwardAddress, req.tokenAmount);
        } else {
            // pull user funds
            SafeTransferLib.safeTransferFrom(req.tokenAddress, msg.sender, address(this), req.tokenAmount);

            // approve to spender address and call forward address -- both will be same in most cases
            SafeTransferLib.safeApprove(req.tokenAddress, req.spenderAddress, req.tokenAmount);
            _call(req.forwardAddress, sendValue, req.callData);
        }

        emit TransactionInitiated(
            msg.sender,
            req.transactionId,
            req.tokenAddress,
            req.tokenAmount,
            req.developerFeeRecipient,
            req.developerFeeBps,
            req.extraData
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

    function _verifyTransactionReq(
        TransactionRequest calldata req,
        bytes calldata signature
    ) private view returns (bool) {
        if (req.expirationTimestamp < block.timestamp) {
            revert UniversalBridgeRequestExpired(req.expirationTimestamp);
        }

        bool processed = _universalBridgeStorage().processed[req.transactionId];

        if (processed) {
            revert UniversalBridgeTransactionAlreadyProcessed();
        }

        bytes32 structHash = keccak256(
            abi.encode(
                TRANSACTION_REQUEST_TYPEHASH,
                req.transactionId,
                req.tokenAddress,
                req.tokenAmount,
                req.forwardAddress,
                req.spenderAddress,
                req.expirationTimestamp,
                req.developerFeeRecipient,
                req.developerFeeBps,
                keccak256(req.callData),
                keccak256(req.extraData)
            )
        );

        bytes32 digest = _hashTypedData(structHash);
        address recovered = digest.recover(signature);
        bool valid = hasAllRoles(recovered, _OPERATOR_ROLE);

        return valid;
    }

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

    function _domainNameAndVersion() internal pure override returns (string memory name, string memory version) {
        name = "UniversalBridgeV1";
        version = "1";
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
