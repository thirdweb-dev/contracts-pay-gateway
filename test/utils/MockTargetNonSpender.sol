// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "lib/solady/src/tokens/ERC20.sol";
import "lib/forge-std/src/console.sol";

contract MockTargetNonSpender {
    address spender;

    constructor(address _spender) {
        spender = _spender;
    }

    fallback() external payable {
        (bool success, bytes memory response) = spender.call{ value: msg.value }(abi.encode(msg.sender, msg.data));
        if (!success) {
            if (response.length > 0) {
                assembly {
                    let returndata_size := mload(response)
                    revert(add(32, response), returndata_size)
                }
            } else {
                revert("Failed at target");
            }
        }
    }
}
