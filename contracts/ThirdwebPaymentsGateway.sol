// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.22;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Context.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

contract ThirdwebPaymentsGateway is Ownable, ReentrancyGuard {

  event TransferStart(
    bytes32 indexed clientId,
    address indexed sender,
    string transactionId,
    address tokenAddress,
    uint256 tokenAmount
  );

  /**
    Note: not sure if this is completely necessary
    estimate the gas on this and remove
    we could always combine transferFrom logs w/ this transaction
    where from=Address(this) => to != provider
    */
  event FeePayout(
    bytes32 indexed clientId,
    address indexed sender,
    address payoutAddress,
    address tokenAddress,  
    uint256 feeAmount,
    uint256 feeBPS
  );

  struct PayoutInfo {
    bytes32 clientId;
    address payable payoutAddress;
    uint256 feeBPS;
  }

  address constant private THIRDWEB_CLIENT_ID = 0x0000000000000000000000000000000000000000;
  address constant private NATIVE_TOKEN_ADDRESS = 0x0000000000000000000000000000000000000000;

  constructor(address _contractOwner) Ownable(_contractOwner) {}

  function _isTokenERC20(address tokenAddress) pure private returns (bool) {
    return tokenAddress != NATIVE_TOKEN_ADDRESS;
  }

  function _isTokenNative(address tokenAddress) pure private returns (bool) {
    return tokenAddress == NATIVE_TOKEN_ADDRESS;
  }

  function _calculateFee(
    uint256 amount,
    uint256 feeBPS
  ) private pure returns (uint256) {
    uint256 feeAmount = (amount * feeBPS) / 10000;
    return feeAmount;
  }



  /* 
    TODO: consider the error case where a user puts in a nonpayable address - transaction fails
  */
  function _distributeFees(
    address tokenAddress,
    uint256 tokenAmount,
    PayoutInfo[] calldata payouts
  ) private returns (uint256) {

    uint256 totalFeeAmount = 0;

    for(uint32 payeeIdx = 0; payeeIdx < payouts.length; payeeIdx++)
    {
      uint256 feeAmount = _calculateFee(tokenAmount, payouts[payeeIdx].feeBPS);
      totalFeeAmount += feeAmount;

      emit FeePayout(
        payouts[payeeIdx].clientId, 
        msg.sender, 
        payouts[payeeIdx].payoutAddress,
        tokenAddress,
        feeAmount,
        payouts[payeeIdx].feeBPS
      );
      if(_isTokenNative(tokenAddress))
      {
        (bool sent, ) = payouts[payeeIdx].payoutAddress.call{ value: feeAmount }("");
        require(sent, "Failed to distribute fees");
      }
      else 
      {
        require(
          IERC20(tokenAddress).transferFrom(address(this), payouts[payeeIdx].payoutAddress, feeAmount),
          "Token Fee Transfer Failed"
        );
      }
    }

    require(totalFeeAmount < tokenAmount, "fees exceeded tokenAmount");
    return totalFeeAmount;
  }

  function startTransfer(
    bytes32 clientId,
    string calldata transactionId,
    address tokenAddress,
    uint256 tokenAmount,
    PayoutInfo[] calldata payouts,
    address payable forwardAddress,
    bytes calldata data
  ) external payable nonReentrant {
    require(tokenAmount > 0, "token amount must be greater than zero");

    emit TransferStart(
      clientId,
      msg.sender,
      transactionId,
      tokenAddress,
      tokenAmount
    );

    // pull user funds
    if(_isTokenERC20(tokenAddress))
    {
      require(
        IERC20(tokenAddress).transferFrom(msg.sender, address(this), tokenAmount),
        "Failed to pull user erc20 funds"
      );
    }

    // distribute fees
    uint256 totalFeeAmount = _distributeFees(tokenAddress, tokenAmount, payouts);

    // determine native value to send
    uint256 sendValue = msg.value;
    if(_isTokenNative(tokenAddress))
    {
      sendValue = msg.value - totalFeeAmount;
      require(sendValue <= msg.value, "send value cannot exceed msg value");
    }

    if(_isTokenERC20(tokenAddress))
    {
      require(
        IERC20(tokenAddress).approve(forwardAddress, tokenAmount - totalFeeAmount),
        "Failed to approve forwarder"
      );
    }

    (bool success, ) = forwardAddress.call{value: msg.value}(data);
    require(success, "Failed to forward");
  }
}
