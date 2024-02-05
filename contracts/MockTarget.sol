// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "hardhat/console.sol";

contract MockTarget {
  event TargetLog(
    address sender,
    address receiver,
    address tokenAddress,
    uint256 tokenAmount,
    string message
  );

  address constant private NATIVE_TOKEN_ADDRESS = 0x0000000000000000000000000000000000000000;

  function decodeData(bytes memory data) private pure returns (address, address, address, uint256, string memory) {
    return abi.decode(data, (address, address, address, uint256, string));
  }

  function performERC20Action(
    address sender,
    address payable receiver,
    address tokenAddress,
    uint256 tokenAmount,
    string memory message
  ) private {
    emit TargetLog(sender, receiver, tokenAddress, tokenAmount, message);
    console.log(
      "Transferring %s erc20 tokens from %s to %s", amount, sender, receiver
    );

    require(IERC20(tokenAddress).transferFrom(msg.sender, receiver, tokenAmount), "Token transfer failed");
  }

  function performNativeTokenAction(
    address sender,
    address payable receiver,
    address tokenAddress,
    uint256 tokenAmount,
    string memory message
  ) private {
    emit TargetLog(sender, receiver, tokenAddress, tokenAmount, message);
    console.log(
      "Transferring %s native tokens from %s to %s", amount, sender, receiver
    );
    (bool sent, ) = receiver.call{value: msg.value}("");
    require(sent, "Failed to send Ether");
  }

  fallback() external payable {
    require(msg.data.length > 0, "data required");
    console.log("Received request!");
    (address sender, address receiver, 
      address tokenAddress, uint256 tokenAmount, 
      string memory message
    ) = decodeData(msg.data);

    if(tokenAddress == NATIVE_TOKEN_ADDRESS)
    {
      console.log("Calling native token action!");
      performNativeTokenAction(payable(sender), payable(receiver), tokenAddress, tokenAmount, message);
    }
    else {
      console.log("Calling erc20 token action!");
      performERC20Action(payable(sender), payable(receiver), tokenAddress, tokenAmount, message);
    }
  }

  receive() external payable {}
}
