// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "lib/solady/src/tokens/ERC20.sol";
import "lib/forge-std/src/console.sol";

contract MockRefundTarget {
    event RefundLog(address sender, address receiver, address tokenAddress, uint256 tokenAmount, uint256 refundAmount, string message);

    address private constant NATIVE_TOKEN_ADDRESS = 0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE;

    function decodeData(bytes memory data) private pure returns (address, address, address, uint256, uint256, string memory) {
        return abi.decode(data, (address, address, address, uint256, uint256, string));
    }

    function performERC20ActionWithRefund(
        address sender,
        address payable receiver,
        address tokenAddress,
        uint256 tokenAmount,
        uint256 refundAmount,
        string memory message
    ) private {
        emit RefundLog(sender, receiver, tokenAddress, tokenAmount, refundAmount, message);
        console.log("Transferring erc20 tokens with refund");

        // First, receive the full tokenAmount from bridge
        require(ERC20(tokenAddress).transferFrom(msg.sender, address(this), tokenAmount), "Token transfer failed");
        
        // Transfer the net amount to receiver (tokenAmount - refundAmount)
        uint256 netAmount = tokenAmount - refundAmount;
        require(ERC20(tokenAddress).transfer(receiver, netAmount), "Transfer to receiver failed");
        
        // Return refund amount back to the bridge contract (msg.sender)
        if (refundAmount > 0) {
            require(ERC20(tokenAddress).transfer(msg.sender, refundAmount), "Refund transfer failed");
        }
    }

    function performNativeTokenActionWithRefund(
        address sender,
        address payable receiver,
        address tokenAddress,
        uint256 tokenAmount,
        uint256 refundAmount,
        string memory message
    ) private {
        emit RefundLog(sender, receiver, tokenAddress, tokenAmount, refundAmount, message);
        console.log("Transferring native tokens with refund");
        
        // Transfer the net amount to receiver (tokenAmount - refundAmount)
        uint256 netAmount = tokenAmount - refundAmount;
        (bool sent, ) = receiver.call{ value: netAmount }("");
        require(sent, "Failed to send Ether");
        
        // Return refund amount back to the bridge contract (msg.sender) 
        if (refundAmount > 0) {
            (bool refundSent, ) = msg.sender.call{ value: refundAmount }("");
            require(refundSent, "Failed to send refund");
        }
    }

    fallback() external payable {
        require(msg.data.length > 0, "data required");
        (
            address sender,
            address receiver,
            address tokenAddress,
            uint256 tokenAmount,
            uint256 refundAmount,
            string memory message
        ) = decodeData(msg.data);

        if (tokenAddress == NATIVE_TOKEN_ADDRESS) {
            console.log("Calling native token action with refund!");
            performNativeTokenActionWithRefund(payable(sender), payable(receiver), tokenAddress, tokenAmount, refundAmount, message);
        } else {
            console.log("Calling erc20 token action with refund!");
            performERC20ActionWithRefund(payable(sender), payable(receiver), tokenAddress, tokenAmount, refundAmount, message);
        }
    }

    receive() external payable {}
}