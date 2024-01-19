// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.22;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/Context.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

contract ThirdwebPaymentsGateway is Ownable {
    event NativeTransferStart(
        string indexed clientId,
        string transactionId,
        address indexed sender
    );
    event ERC20TransferStart(
        string indexed clientId,
        string transactionId,
        address indexed sender,
        address token,
        uint256 amount
    );

    address payable private payoutAddress;
    address payable private lifiContractAddress;
    uint256 private feeBPS;

    constructor(
        address _contractOwner,
        address payable _payoutAddress,
        address payable _lifiContractAddress,
        uint256 _feeBPS
    ) Ownable(_contractOwner) {
        payoutAddress = _payoutAddress;
        lifiContractAddress = _lifiContractAddress;
        feeBPS = _feeBPS;
    }

    function setPayoutAddress(
        address payable _payoutAddress
    ) external onlyOwner {
        payoutAddress = _payoutAddress;
    }

    function setFee(uint256 _feeBPS) external onlyOwner {
        feeBPS = _feeBPS;
    }

    function _calculateFee(
        uint256 _amount,
        uint256 _feeBPS
    ) private pure returns (uint256) {
        uint256 fee = (_amount * _feeBPS) / 10000;
        return fee;
    }

    function nativeTransfer(
        string calldata clientId,
        string calldata transactionId,
        bytes calldata data
    ) external payable {
        require(msg.value > 0, "No ether sent");

        emit NativeTransferStart(clientId, transactionId, msg.sender);

        uint256 fee = _calculateFee(msg.value, feeBPS);

        (bool sent, ) = payoutAddress.call{value: fee}("");
        require(sent, "Failed to send ether");

        (bool success, ) = lifiContractAddress.call{value: msg.value - fee}(
            data
        );
        require(success, "Forward failed");
    }

    function erc20Transfer(
        string calldata clientId,
        string calldata transactionId,
        address tokenAddress,
        uint256 tokenAmount,
        bytes calldata data
    ) external payable {
        require(tokenAmount > 0, "Amount must be greater than zero");

        emit ERC20TransferStart(
            clientId,
            transactionId,
            msg.sender,
            tokenAddress,
            tokenAmount
        );

        IERC20 token = IERC20(tokenAddress);

        uint256 fee = _calculateFee(tokenAmount, feeBPS); // make sure floor

        require(
            token.transferFrom(msg.sender, payoutAddress, fee),
            "Token Fee Transfer Failed"
        );

        uint256 amountAfterFee = tokenAmount - fee;

        require(
            token.transferFrom(msg.sender, address(this), amountAfterFee),
            "Token Transfer Failed"
        );

        require(
            token.approve(lifiContractAddress, amountAfterFee),
            "Token Approval Failed"
        );

        (bool success, ) = lifiContractAddress.call{value: msg.value}(data);
        require(success, "Forward failed");
    }
}
