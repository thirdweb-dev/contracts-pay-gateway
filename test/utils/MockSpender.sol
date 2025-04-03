// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "lib/solady/src/tokens/ERC20.sol";
import "lib/forge-std/src/console.sol";

contract MockSpender {
    event TargetLog(address sender, address receiver, address tokenAddress, uint256 tokenAmount, string message);

    address private constant NATIVE_TOKEN_ADDRESS = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    function decodeData(bytes memory data) private pure returns (address, address, address, uint256, string memory) {
        return abi.decode(data, (address, address, address, uint256, string));
    }

    function performERC20Action(
        address gateway,
        address sender,
        address payable receiver,
        address tokenAddress,
        uint256 tokenAmount,
        string memory message
    ) private {
        emit TargetLog(sender, receiver, tokenAddress, tokenAmount, message);
        console.log("Transferring %s erc20 tokens from %s to %s", tokenAmount, sender, receiver);

        require(ERC20(tokenAddress).transferFrom(gateway, receiver, tokenAmount), "Token transfer failed");
    }

    function performNativeTokenAction(
        address gateway,
        address sender,
        address payable receiver,
        address tokenAddress,
        uint256 tokenAmount,
        string memory message
    ) private {
        emit TargetLog(sender, receiver, tokenAddress, tokenAmount, message);
        console.log("Transferring %s native tokens from %s to %s", tokenAmount, sender, receiver);
        (bool sent, ) = receiver.call{ value: msg.value }("");
        require(sent, "Failed to send Ether");
    }

    fallback() external payable {
        require(msg.data.length > 0, "data required");
        (address gateway, bytes memory data) = abi.decode(msg.data, (address, bytes));
        (
            address sender,
            address receiver,
            address tokenAddress,
            uint256 tokenAmount,
            string memory message
        ) = decodeData(data);

        if (tokenAddress == NATIVE_TOKEN_ADDRESS) {
            console.log("Calling native token action!");
            performNativeTokenAction(gateway, payable(sender), payable(receiver), tokenAddress, tokenAmount, message);
        } else {
            console.log("Calling erc20 token action!");
            performERC20Action(gateway, payable(sender), payable(receiver), tokenAddress, tokenAmount, message);
        }
    }

    receive() external payable {}
}
