// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import { Test, console, console2 } from "forge-std/Test.sol";
import { PaymentsGatewaySplit } from "src/PaymentsGatewaySplit.sol";
import { MockERC20 } from "./utils/MockERC20.sol";
import { MockTarget } from "./utils/MockTarget.sol";

contract PaymentsGatewaySplitTest is Test {
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

    event FeePayout(address indexed sender, address payoutAddress, address tokenAddress, uint256 feeAmount);

    event OperatorChanged(address indexed previousOperator, address indexed newOperator);

    PaymentsGatewaySplit internal gateway;
    MockERC20 internal mockERC20;
    MockTarget internal mockTarget;

    address payable internal owner;
    address payable internal operator;
    address payable internal sender;
    address payable internal receiver;
    address payable internal client;
    address payable internal feeRecipient;
    uint256 internal feeAmount;
    bytes32 internal clientId;

    bytes32 internal typehashPayRequest;
    bytes32 internal nameHash;
    bytes32 internal versionHash;
    bytes32 internal typehashEip712;
    bytes32 internal domainSeparator;

    function setUp() public {
        owner = payable(vm.addr(1));
        operator = payable(vm.addr(2));
        sender = payable(vm.addr(3));
        receiver = payable(vm.addr(4));
        client = payable(vm.addr(5));
        feeRecipient = payable(vm.addr(6));

        clientId = keccak256("client");

        gateway = new PaymentsGatewaySplit(owner, operator);
        mockERC20 = new MockERC20("Token", "TKN");
        mockTarget = new MockTarget();

        // fund the sender
        mockERC20.mint(sender, 10 ether);
        vm.deal(sender, 10 ether);

        // EIP712
        typehashPayRequest = keccak256(
            "PayRequest(bytes32 clientId,bytes32 transactionId,address tokenAddress,uint256 tokenAmount,address payable feeRecipient,uint256 fee,address payable forwardAddress,bytes data)"
        );
        nameHash = keccak256(bytes("PaymentsGateway"));
        versionHash = keccak256(bytes("1"));
        typehashEip712 = keccak256(
            "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
        );
        domainSeparator = keccak256(abi.encode(typehashEip712, nameHash, versionHash, block.chainid, address(gateway)));
    }

    /*///////////////////////////////////////////////////////////////
                        internal util functions
    //////////////////////////////////////////////////////////////*/

    function _buildMockTargetCalldata(
        address _sender,
        address _receiver,
        address _token,
        uint256 _sendValue,
        string memory _message
    ) internal pure returns (bytes memory data) {
        data = abi.encode(_sender, _receiver, _token, _sendValue, _message);
    }

    function _prepareAndSignData(
        uint256 _operatorPrivateKey,
        PaymentsGatewaySplit.PayRequest memory req
    ) internal view returns (bytes memory signature) {
        bytes memory dataToHash;
        {
            dataToHash = abi.encode(
                typehashPayRequest,
                req.clientId,
                req.transactionId,
                req.tokenAddress,
                req.tokenAmount,
                req.feeRecipient,
                req.fee,
                req.forwardAddress,
                req.data
            );
        }

        {
            bytes32 _structHash = keccak256(dataToHash);
            bytes32 typedDataHash = keccak256(abi.encodePacked("\x19\x01", domainSeparator, _structHash));
            (uint8 v, bytes32 r, bytes32 s) = vm.sign(_operatorPrivateKey, typedDataHash);

            signature = abi.encodePacked(r, s, v);
        }
    }

    /*///////////////////////////////////////////////////////////////
                    Test `startTransfer`
    //////////////////////////////////////////////////////////////*/

    function test_startTransfer_erc20() public {
        uint256 sendValue = 1 ether;
        feeAmount = 0.1 ether;
        uint256 sendValueWithFees = sendValue + feeAmount;
        bytes memory targetCalldata = _buildMockTargetCalldata(sender, receiver, address(mockERC20), sendValue, "");

        // approve amount to gateway contract
        vm.prank(sender);
        mockERC20.approve(address(gateway), sendValueWithFees);

        // create pay request
        PaymentsGatewaySplit.PayRequest memory req;
        bytes32 _transactionId = keccak256("transaction ID");

        req.clientId = clientId;
        req.transactionId = _transactionId;
        req.tokenAddress = address(mockERC20);
        req.tokenAmount = sendValue;
        req.forwardAddress = payable(address(mockTarget));
        req.data = targetCalldata;
        req.feeRecipient = feeRecipient;
        req.fee = feeAmount;

        // generate signature
        bytes memory _signature = _prepareAndSignData(
            2, // sign with operator private key, i.e. 2
            req
        );

        // state/balances before sending transaction
        uint256 feeRecipientBalanceBefore = mockERC20.balanceOf(feeRecipient);
        uint256 senderBalanceBefore = mockERC20.balanceOf(sender);
        uint256 receiverBalanceBefore = mockERC20.balanceOf(receiver);

        // send transaction
        vm.prank(sender);
        gateway.startTransfer(req, _signature);

        // check balances after transaction
        assertEq(mockERC20.balanceOf(feeRecipient), feeRecipientBalanceBefore + feeAmount);
        assertEq(mockERC20.balanceOf(sender), senderBalanceBefore - sendValueWithFees);
        assertEq(mockERC20.balanceOf(receiver), receiverBalanceBefore + sendValue);
    }

    function test_startTransfer_nativeToken() public {
        uint256 sendValue = 1 ether;
        feeAmount = 0.1 ether;
        uint256 sendValueWithFees = sendValue + feeAmount;
        bytes memory targetCalldata = _buildMockTargetCalldata(sender, receiver, address(0), sendValue, "");

        // create pay request
        PaymentsGatewaySplit.PayRequest memory req;
        bytes32 _transactionId = keccak256("transaction ID");

        req.clientId = clientId;
        req.transactionId = _transactionId;
        req.tokenAddress = address(0);
        req.tokenAmount = sendValue;
        req.forwardAddress = payable(address(mockTarget));
        req.data = targetCalldata;
        req.feeRecipient = feeRecipient;
        req.fee = feeAmount;

        // generate signature
        bytes memory _signature = _prepareAndSignData(
            2, // sign with operator private key, i.e. 2
            req
        );

        // state/balances before sending transaction
        uint256 feeRecipientBalanceBefore = feeRecipient.balance;
        uint256 senderBalanceBefore = sender.balance;
        uint256 receiverBalanceBefore = receiver.balance;

        // send transaction
        vm.prank(sender);
        gateway.startTransfer{ value: sendValueWithFees }(req, _signature);

        // check balances after transaction
        assertEq(feeRecipient.balance, feeRecipientBalanceBefore + feeAmount);
        assertEq(sender.balance, senderBalanceBefore - sendValueWithFees);
        assertEq(receiver.balance, receiverBalanceBefore + sendValue);
    }

    function test_startTransfer_events() public {
        uint256 sendValue = 1 ether;
        feeAmount = 0.1 ether;
        uint256 sendValueWithFees = sendValue + feeAmount;
        bytes memory targetCalldata = _buildMockTargetCalldata(sender, receiver, address(0), sendValue, "");

        // approve amount to gateway contract
        vm.prank(sender);
        mockERC20.approve(address(gateway), sendValueWithFees);

        // create pay request
        PaymentsGatewaySplit.PayRequest memory req;
        bytes32 _transactionId = keccak256("transaction ID");

        req.clientId = clientId;
        req.transactionId = _transactionId;
        req.tokenAddress = address(mockERC20);
        req.tokenAmount = sendValue;
        req.forwardAddress = payable(address(mockTarget));
        req.data = targetCalldata;
        req.feeRecipient = feeRecipient;
        req.fee = feeAmount;

        // generate signature
        bytes memory _signature = _prepareAndSignData(
            2, // sign with operator private key, i.e. 2
            req
        );

        // send transaction
        vm.prank(sender);
        vm.expectEmit(true, true, false, true);
        emit TransferStart(req.clientId, sender, _transactionId, req.tokenAddress, req.tokenAmount);
        gateway.startTransfer(req, _signature);
    }

    function test_revert_startTransfer_invalidSignature() public {
        uint256 sendValue = 1 ether;
        feeAmount = 0.1 ether;
        uint256 sendValueWithFees = sendValue + feeAmount;
        bytes memory targetCalldata = _buildMockTargetCalldata(sender, receiver, address(0), sendValue, "");

        // create pay request
        PaymentsGatewaySplit.PayRequest memory req;
        bytes32 _transactionId = keccak256("transaction ID");

        req.clientId = clientId;
        req.transactionId = _transactionId;
        req.tokenAddress = address(0);
        req.tokenAmount = sendValue;
        req.forwardAddress = payable(address(mockTarget));
        req.data = targetCalldata;
        req.feeRecipient = feeRecipient;
        req.fee = feeAmount;

        // generate signature
        bytes memory _signature = _prepareAndSignData(
            123, // sign with random key
            req
        );

        // send transaction
        vm.prank(sender);
        vm.expectRevert(abi.encodeWithSelector(PaymentsGatewaySplit.PaymentsGatewayVerificationFailed.selector));
        gateway.startTransfer(req, _signature);
    }

    // /*///////////////////////////////////////////////////////////////
    //                 Test `endTransfer`
    // //////////////////////////////////////////////////////////////*/

    function test_endTransfer_erc20() public {
        uint256 sendValue = 1 ether;

        // approve amount to gateway contract
        vm.prank(sender);
        mockERC20.approve(address(gateway), sendValue);

        // state/balances before sending transaction
        uint256 ownerBalanceBefore = mockERC20.balanceOf(owner);
        uint256 senderBalanceBefore = mockERC20.balanceOf(sender);
        uint256 receiverBalanceBefore = mockERC20.balanceOf(receiver);

        // send transaction
        bytes32 _transactionId = keccak256("transaction ID");
        vm.prank(sender);
        gateway.endTransfer(clientId, _transactionId, address(mockERC20), sendValue, receiver);

        // check balances after transaction
        assertEq(mockERC20.balanceOf(owner), ownerBalanceBefore);
        assertEq(mockERC20.balanceOf(sender), senderBalanceBefore - sendValue);
        assertEq(mockERC20.balanceOf(receiver), receiverBalanceBefore + sendValue);
    }

    function test_endTransfer_nativeToken() public {
        uint256 sendValue = 1 ether;

        // state/balances before sending transaction
        uint256 ownerBalanceBefore = owner.balance;
        uint256 senderBalanceBefore = sender.balance;
        uint256 receiverBalanceBefore = receiver.balance;

        // send transaction
        bytes32 _transactionId = keccak256("transaction ID");
        vm.prank(sender);
        gateway.endTransfer{ value: sendValue }(clientId, _transactionId, address(0), sendValue, receiver);

        // check balances after transaction
        assertEq(owner.balance, ownerBalanceBefore);
        assertEq(sender.balance, senderBalanceBefore - sendValue);
        assertEq(receiver.balance, receiverBalanceBefore + sendValue);
    }

    function test_endTransfer_events() public {
        uint256 sendValue = 1 ether;

        // approve amount to gateway contract
        vm.prank(sender);
        mockERC20.approve(address(gateway), sendValue);

        // send transaction
        bytes32 _transactionId = keccak256("transaction ID");
        vm.prank(sender);
        vm.expectEmit(true, true, false, true);
        emit TransferEnd(clientId, receiver, _transactionId, address(mockERC20), sendValue);
        gateway.endTransfer(clientId, _transactionId, address(mockERC20), sendValue, receiver);
    }
}
