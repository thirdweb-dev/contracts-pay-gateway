// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.22;

import { ModularCore } from "lib/modular-contracts/src/ModularCore.sol";
import { Initializable } from "lib/solady/src/utils/Initializable.sol";

contract PayGateway is ModularCore, Initializable {
    constructor() {
        _disableInitializers();
    }

    function initialize(address _owner, address[] memory _modules, bytes[] memory _moduleInstallData) external payable {
        _initializeOwner(_owner);

        // Install and initialize modules
        require(_modules.length == _moduleInstallData.length);
        for (uint256 i = 0; i < _modules.length; i++) {
            _installModule(_modules[i], _moduleInstallData[i]);
        }
    }

    function getSupportedCallbackFunctions()
        public
        pure
        override
        returns (SupportedCallbackFunction[] memory supportedCallbackFunctions)
    {}
}
