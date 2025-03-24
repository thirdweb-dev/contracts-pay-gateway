// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.22;

contract UniversalGatewayProxy {
    bytes32 private constant _ERC1967_IMPLEMENTATION_SLOT =
        0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    constructor(address _implementation, address _defaultAdmin, address payable _payoutAddress, uint256 _feeBps) {
        require(_implementation != address(0), "Invalid implementation address");
        assembly {
            sstore(_ERC1967_IMPLEMENTATION_SLOT, _implementation)
        }

        bytes memory data = abi.encodeWithSignature(
            "initialize(address,address,uint256)",
            _defaultAdmin,
            _payoutAddress,
            _feeBps
        );
        (bool success, ) = _implementation.delegatecall(data);
        require(success, "Initialization failed");
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
