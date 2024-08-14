// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "lib/solady/src/tokens/ERC20.sol";

contract MockERC20 is ERC20 {
    string private _name;
    string private _symbol;

    constructor(string memory name, string memory symbol) {
        _name = name;
        _symbol = symbol;
    }

    function name() public view override returns (string memory) {
        return _name;
    }

    function symbol() public view override returns (string memory) {
        return _symbol;
    }

    function mint(address to, uint256 amount) public {
        _mint(to, amount);
    }
}
