// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.22;

import { ModularCore } from "lib/modular-contracts/src/ModularCore.sol";
import { Initializable } from "lib/solady/src/utils/Initializable.sol";

contract ModularPaymentsGateway is ModularCore, Initializable {
    constructor() {
        _disableInitializers();
    }

    function initialize(
        address _owner,
        address[] memory _extensions,
        bytes[] memory _extensionInstallData
    ) external payable {
        _initializeOwner(_owner);

        // Install and initialize extensions
        require(_extensions.length == _extensionInstallData.length);
        for (uint256 i = 0; i < _extensions.length; i++) {
            _installExtension(_extensions[i], _extensionInstallData[i]);
        }
    }

    function getSupportedCallbackFunctions()
        public
        pure
        override
        returns (SupportedCallbackFunction[] memory supportedCallbackFunctions)
    {}
}
