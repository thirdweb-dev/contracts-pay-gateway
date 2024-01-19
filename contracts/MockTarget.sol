// SPDX-License-Identifier: MIT
pragma solidity ^0.8.22;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "hardhat/console.sol";

contract MockTarget {
    event LogMessage(string message);

    function performERC20Action(
        address token,
        uint256 amount,
        address toAddress,
        string calldata message
    ) external {
        // Log the message string
        emit LogMessage(message);
        console.log(
            "Transferring %s tokens from %s to %s",
            amount,
            msg.sender,
            toAddress
        );
        // Transfer the tokens
        bool success = IERC20(token).transferFrom(
            msg.sender,
            toAddress,
            amount
        );
        require(success, "Token transfer failed");
    }

    function performNativeTokenAction(
        address payable toAddress,
        string calldata message
    ) external payable {
        emit LogMessage(message);

        (bool sent, ) = toAddress.call{value: msg.value}("");
        require(sent, "Failed to send the funds");
    }
}
