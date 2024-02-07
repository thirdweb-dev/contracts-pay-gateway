// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.22;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Context.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

/**
  Requirements
  - easily change fee / payout structure per transaction
  - easily change provider per transaction

  TODO: 
    - add receiver function
    - add thirdweb signer for tamperproofing
    - add operator role automating withdrawals
 */

contract ThirdwebPaymentsGateway is Ownable, ReentrancyGuard {

  event TransferStart(
    bytes32 indexed clientId,
    address indexed sender,
    bytes32 transactionId,
    address tokenAddress,
    uint256 tokenAmount
  );

  event TransferEnd(
    bytes32 indexed clientId,
    address indexed receiver,
    bytes32 transactionId,
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

  event OperatorChanged(address indexed previousOperator, address indexed newOperator);

  struct PayoutInfo {
    bytes32 clientId;
    address payable payoutAddress;
    uint256 feeBPS;
  }

  address constant private THIRDWEB_CLIENT_ID = 0x0000000000000000000000000000000000000000;
  address constant private NATIVE_TOKEN_ADDRESS = 0x0000000000000000000000000000000000000000;
  address private _operator;

  constructor(address contractOwner, address initialOperator) Ownable(contractOwner) {
    require(initialOperator != address(0), "Operator can't be the zero address");
    _operator = initialOperator;
    emit OperatorChanged(address(0), initialOperator);
  }

  modifier onlyOwnerOrOperator() {
    require(msg.sender == owner() || msg.sender == _operator, "Caller is not the owner or operator");
    _;
}

  function setOperator(address newOperator) public onlyOwnerOrOperator {
    require(newOperator != address(0), "Operator can't be the zero address");
    emit OperatorChanged(_operator, newOperator);
    _operator = newOperator;
  }

  function getOperator() public view returns (address) {
    return _operator;
  }

  /* some bridges may refund need a way to get funds back to user */
  function withdrawTo(address tokenAddress, uint256 tokenAmount, address payable receiver) public onlyOwnerOrOperator nonReentrant
  {
    if(_isTokenERC20(tokenAddress))
    {
      require(
        IERC20(tokenAddress).transferFrom(address(this), receiver, tokenAmount),
        "Failed to withdraw funds"
      );
    } else {
      (bool sent, ) = receiver.call{ value: tokenAmount }("");
      require(sent, "Failed to withdraw funds");
    }
  }

  function withdraw(address tokenAddress, uint256 tokenAmount) external onlyOwnerOrOperator nonReentrant {
    withdrawTo(tokenAddress, tokenAmount, payable(msg.sender));
  } 


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
    uint256 feeAmount = (amount * feeBPS) / 10_000;
    return feeAmount;
  }

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
          IERC20(tokenAddress).transferFrom(msg.sender, payouts[payeeIdx].payoutAddress, feeAmount),
          "Token Fee Transfer Failed"
        );
      }
    }

    require(totalFeeAmount < tokenAmount, "fees exceeded tokenAmount");
    return totalFeeAmount;
  }


  function _hashPayoutInfo(PayoutInfo[] calldata payouts) private pure returns (bytes32) {
    bytes32 payoutHash = keccak256(abi.encodePacked("PayoutInfo"));
    for (uint256 i = 0; i < payouts.length; ++i) {
        payoutHash = keccak256(abi.encodePacked(
            payoutHash,
            payouts[i].clientId,
            payouts[i].payoutAddress,
            payouts[i].feeBPS
        ));
    }
    return payoutHash;
}

  function _verifyTransferStart(
    bytes32 clientId,
    bytes32 transactionId,
    address tokenAddress,
    uint256 tokenAmount,
    PayoutInfo[] calldata payouts,
    address payable forwardAddress,
    bytes calldata data,
    bytes calldata signature
  ) private returns (bool)
  {
    bytes32 payoutsHash = _hashPayoutInfo(payouts);
    bytes32 hash = keccak256(
        abi.encodePacked(
            clientId,
            transactionId,
            tokenAddress,
            tokenAmount,
            payoutsHash,
            forwardAddress,
            data
        )
    );

    bytes32 ethSignedMsgHash = keccak256(
        abi.encodePacked("\x19Ethereum Signed Message:\n32", hash)
    );

    (address recovered, bool valid) = _recoverSigner(ethSignedMsgHash, signature);
    return valid && recovered == _operator;
  }

  function _recoverSigner(bytes32 ethSignedMsgHash, bytes memory signature) public pure returns (address, bool) {
    bytes32 r;
    bytes32 s;
    uint8 v;

    if (signature.length != 65) {
      return (address(0), false);
    }

    assembly {
        r := mload(add(signature, 0x20))
        s := mload(add(signature, 0x40))
        v := byte(0, mload(add(signature, 0x60)))
    }

    if (v < 27) {
        v += 27;
    }

    address recovered = ecrecover(ethSignedMsgHash, v, r, s);
    bool valid = (recovered != address(0));

    return (recovered, valid);
  }

  function startTransfer(
    bytes32 clientId,
    bytes32 transactionId,
    address tokenAddress,
    uint256 tokenAmount,
    PayoutInfo[] calldata payouts,
    address payable forwardAddress,
    bytes calldata data,
    bytes calldata signature
  ) external payable nonReentrant {
    // verify amount
    require(tokenAmount > 0, "token amount must be greater than zero");

    // verify data
    require(_verifyTransferStart(
      clientId,
      transactionId,
      tokenAddress,
      tokenAmount,
      payouts,
      forwardAddress,
      data,
      signature
    ), "failed to verify transaction");
    
    if(_isTokenNative(tokenAddress))
    {
      require(msg.value >= tokenAmount, "msg value must be gte than token amount");
    }

    emit TransferStart(
      clientId,
      msg.sender,
      transactionId,
      tokenAddress,
      tokenAmount
    );

    // distribute fees
    uint256 totalFeeAmount = _distributeFees(tokenAddress, tokenAmount, payouts);

    // determine native value to send
    uint256 sendValue = msg.value;
    if(_isTokenNative(tokenAddress))
    {
      sendValue = msg.value - totalFeeAmount;
      require(sendValue <= msg.value, "send value cannot exceed msg value");
      require(sendValue >= tokenAmount, "send value must cover tokenAmount");
    }

    if(_isTokenERC20(tokenAddress))
    {
      // pull user funds
      require(
        IERC20(tokenAddress).transferFrom(msg.sender, address(this), tokenAmount),
        "Failed to pull user erc20 funds"
      );

      require(
        IERC20(tokenAddress).approve(forwardAddress, tokenAmount),
        "Failed to approve forwarder"
      );
    }

    (bool success, ) = forwardAddress.call{value: sendValue }(data);
    require(success, "Failed to forward");
  }

  function endTransfer(
    bytes32 clientId,
    bytes32 transactionId,
    address tokenAddress, 
    uint256 tokenAmount,
    address payable receiverAddress
  ) external payable nonReentrant {
    require(tokenAmount > 0, "token amount must be greater than zero");

    if(_isTokenNative(tokenAddress))
    {
      require(msg.value >= tokenAmount, "msg value must be gte token amount");
    }

    emit TransferEnd(
      clientId,
      receiverAddress,
      transactionId,
      tokenAddress,
      tokenAmount
    );

    // pull user funds
    if(_isTokenERC20(tokenAddress))
    {
      require(
        IERC20(tokenAddress).transferFrom(msg.sender, receiverAddress, tokenAmount),
        "Failed to forward erc20 funds"
      );
    }
    else {
      (bool success, ) = receiverAddress.call{value: tokenAmount }("");
      require(success, "Failed to send to reciever");
    }
  }
}
