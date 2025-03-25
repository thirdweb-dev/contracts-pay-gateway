// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.22;

contract UniversalGatewayProxy {
    error ImplementationZeroAddress();
    error ImplementationDoesNotExist();
    error OwnerZeroAddress();
    error InitializationFailed();

    bytes32 private constant _ERC1967_IMPLEMENTATION_SLOT =
        0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    constructor(
        address _implementation,
        address _owner,
        address payable _protocolFeeRecipient,
        uint256 _protocolFeeBps
    ) {
        if (_implementation == address(0)) {
            revert ImplementationZeroAddress();
        }

        if (_implementation.code.length == 0) {
            revert ImplementationDoesNotExist();
        }

        if (_owner == address(0)) {
            revert OwnerZeroAddress();
        }

        assembly {
            sstore(_ERC1967_IMPLEMENTATION_SLOT, _implementation)
        }

        bytes memory data = abi.encodeWithSignature(
            "initialize(address,address,uint256)",
            _owner,
            _protocolFeeRecipient,
            _protocolFeeBps
        );
        (bool success, ) = _implementation.delegatecall(data);

        if (!success) {
            revert InitializationFailed();
        }
    }

    receive() external payable {}

    fallback() external payable {
        assembly {
            let _impl := sload(_ERC1967_IMPLEMENTATION_SLOT)
            calldatacopy(0, 0, calldatasize())
            let result := delegatecall(gas(), _impl, 0, calldatasize(), 0, 0)
            returndatacopy(0, 0, returndatasize())
            switch result
            case 0 {
                revert(0, returndatasize())
            }
            default {
                return(0, returndatasize())
            }
        }
    }

    function getImplementation() external view returns (address impl) {
        assembly {
            impl := sload(_ERC1967_IMPLEMENTATION_SLOT)
        }
    }
}
