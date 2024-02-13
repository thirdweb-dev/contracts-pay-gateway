// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import { Test, console2 } from "forge-std/Test.sol";
import { ThirdwebPaymentsGateway } from "contracts/ThirdwebPaymentsGateway.sol";
import { MockERC20 } from "./utils/MockERC20.sol";
import { MockTarget } from "./utils/MockTarget.sol";

import "lib/forge-std/src/console.sol";

contract ThirdwebPaymentsGatewayTest is Test {
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

    event FeePayout(
        bytes32 indexed clientId,
        address indexed sender,
        address payoutAddress,
        address tokenAddress,
        uint256 feeAmount,
        uint256 feeBPS
    );

    event OperatorChanged(address indexed previousOperator, address indexed newOperator);

    ThirdwebPaymentsGateway internal gateway;
    MockERC20 internal mockERC20;
    MockTarget internal mockTarget;

    address payable internal owner;
    address payable internal operator;
    address payable internal sender;
    address payable internal receiver;
    address payable internal client;

    bytes32 internal ownerClientId;
    bytes32 internal clientId;

    uint256 internal ownerFeeBps;
    uint256 internal clientFeeBps;
    uint256 internal totalFeeBps;

    ThirdwebPaymentsGateway.PayoutInfo[] internal payouts;

    function setUp() public {
        owner = payable(vm.addr(1));
        operator = payable(vm.addr(2));
        sender = payable(vm.addr(3));
        receiver = payable(vm.addr(4));
        client = payable(vm.addr(5));

        ownerClientId = keccak256("owner");
        clientId = keccak256("client");

        ownerFeeBps = 200;
        clientFeeBps = 100;

        gateway = new ThirdwebPaymentsGateway(owner, operator);
        mockERC20 = new MockERC20("Token", "TKN");
        mockTarget = new MockTarget();

        // fund the sender
        mockERC20.mint(sender, 10 ether);
        vm.deal(sender, 10 ether);

        // build payout info
        payouts.push(
            ThirdwebPaymentsGateway.PayoutInfo({ clientId: ownerClientId, payoutAddress: owner, feeBPS: ownerFeeBps })
        );
        payouts.push(
            ThirdwebPaymentsGateway.PayoutInfo({ clientId: clientId, payoutAddress: client, feeBPS: clientFeeBps })
        );
        for (uint256 i = 0; i < payouts.length; i++) {
            totalFeeBps += payouts[i].feeBPS;
        }
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
    ) internal returns (bytes memory data) {
        data = abi.encode(_sender, _receiver, _token, _sendValue, _message);
    }

    function _hashPayoutInfo(ThirdwebPaymentsGateway.PayoutInfo[] memory _payouts) private pure returns (bytes32) {
        bytes32 payoutHash = keccak256(abi.encodePacked("PayoutInfo"));
        for (uint256 i = 0; i < _payouts.length; ++i) {
            payoutHash = keccak256(
                abi.encodePacked(payoutHash, _payouts[i].clientId, _payouts[i].payoutAddress, _payouts[i].feeBPS)
            );
        }
        return payoutHash;
    }

    function _prepareAndSignData(
        uint256 _operatorPrivateKey,
        bytes32 _clientId,
        bytes32 _transactionId,
        address _tokenAddress,
        uint256 _tokenAmount,
        address _forwardAddress,
        bytes memory _targetCalldata
    ) internal returns (bytes memory signature) {
        bytes memory dataToHash;
        {
            bytes32 _payoutsHash = _hashPayoutInfo(payouts);
            dataToHash = abi.encodePacked(
                _clientId,
                _transactionId,
                _tokenAddress,
                _tokenAmount,
                _payoutsHash,
                _forwardAddress,
                _targetCalldata
            );
        }

        {
            bytes32 _hash = keccak256(dataToHash);
            bytes32 ethSignedMsgHash = keccak256(abi.encodePacked("\x19Ethereum Signed Message:\n32", _hash));
            (uint8 v, bytes32 r, bytes32 s) = vm.sign(_operatorPrivateKey, ethSignedMsgHash);

            signature = abi.encodePacked(r, s, v);
        }
    }

    /*///////////////////////////////////////////////////////////////
                    Test `startTransfer` with ERC20
    //////////////////////////////////////////////////////////////*/

    function test_startTransfer_erc20() public {
        uint256 sendValue = 1 ether;
        uint256 sendValueWithFees = sendValue + (sendValue * totalFeeBps) / 10_000;
        bytes memory targetCalldata = _buildMockTargetCalldata(sender, receiver, address(mockERC20), sendValue, "");

        // approve amount to gateway contract
        vm.prank(sender);
        mockERC20.approve(address(gateway), sendValueWithFees);

        // generate signature
        bytes32 _transactionId = keccak256("transaction ID");
        bytes memory _signature = _prepareAndSignData(
            2, // sign with operator private key, i.e. 2
            clientId,
            _transactionId,
            address(mockERC20),
            sendValue,
            address(mockTarget),
            targetCalldata
        );

        // state/balances before sending transaction
        uint256 ownerBalanceBefore = mockERC20.balanceOf(owner);
        uint256 clientBalanceBefore = mockERC20.balanceOf(client);
        uint256 senderBalanceBefore = mockERC20.balanceOf(sender);
        uint256 receiverBalanceBefore = mockERC20.balanceOf(receiver);

        // send transaction
        vm.prank(sender);
        gateway.startTransfer(
            clientId,
            _transactionId,
            address(mockERC20),
            sendValue,
            payouts,
            payable(address(mockTarget)),
            targetCalldata,
            _signature
        );

        // check balances after transaction
        assertEq(mockERC20.balanceOf(owner), ownerBalanceBefore + (sendValue * ownerFeeBps) / 10_000);
        assertEq(mockERC20.balanceOf(client), clientBalanceBefore + (sendValue * clientFeeBps) / 10_000);
        assertEq(mockERC20.balanceOf(sender), senderBalanceBefore - sendValueWithFees);
        assertEq(mockERC20.balanceOf(receiver), receiverBalanceBefore + sendValue);
    }

    function test_startTransfer_nativeToken() public {
        uint256 sendValue = 1 ether;
        uint256 sendValueWithFees = sendValue + (sendValue * totalFeeBps) / 10_000;
        bytes memory targetCalldata = _buildMockTargetCalldata(sender, receiver, address(0), sendValue, "");

        // generate signature
        bytes32 _transactionId = keccak256("transaction ID");
        bytes memory _signature = _prepareAndSignData(
            2, // sign with operator private key, i.e. 2
            clientId,
            _transactionId,
            address(0),
            sendValue,
            address(mockTarget),
            targetCalldata
        );

        // state/balances before sending transaction
        uint256 ownerBalanceBefore = owner.balance;
        uint256 clientBalanceBefore = client.balance;
        uint256 senderBalanceBefore = sender.balance;
        uint256 receiverBalanceBefore = receiver.balance;

        // send transaction
        vm.prank(sender);
        gateway.startTransfer{ value: sendValueWithFees }(
            clientId,
            _transactionId,
            address(0),
            sendValue,
            payouts,
            payable(address(mockTarget)),
            targetCalldata,
            _signature
        );

        // check balances after transaction
        assertEq(owner.balance, ownerBalanceBefore + (sendValue * ownerFeeBps) / 10_000);
        assertEq(client.balance, clientBalanceBefore + (sendValue * clientFeeBps) / 10_000);
        assertEq(sender.balance, senderBalanceBefore - sendValueWithFees);
        assertEq(receiver.balance, receiverBalanceBefore + sendValue);
    }

    function test_startTransfer_events() public {
        uint256 sendValue = 1 ether;
        uint256 sendValueWithFees = sendValue + (sendValue * totalFeeBps) / 10_000;
        bytes memory targetCalldata = _buildMockTargetCalldata(sender, receiver, address(mockERC20), sendValue, "");

        // approve amount to gateway contract
        vm.prank(sender);
        mockERC20.approve(address(gateway), sendValueWithFees);

        // generate signature
        bytes32 _transactionId = keccak256("transaction ID");
        bytes memory _signature = _prepareAndSignData(
            2, // sign with operator private key, i.e. 2
            clientId,
            _transactionId,
            address(mockERC20),
            sendValue,
            address(mockTarget),
            targetCalldata
        );

        // send transaction
        vm.prank(sender);
        vm.expectEmit(true, true, false, true);
        emit TransferStart(clientId, sender, _transactionId, address(mockERC20), sendValue);
        gateway.startTransfer(
            clientId,
            _transactionId,
            address(mockERC20),
            sendValue,
            payouts,
            payable(address(mockTarget)),
            targetCalldata,
            _signature
        );
    }

    function test_revert_startTransfer_invalidSignature() public {
        uint256 sendValue = 1 ether;
        uint256 sendValueWithFees = sendValue + (sendValue * totalFeeBps) / 10_000;
        bytes memory targetCalldata = _buildMockTargetCalldata(sender, receiver, address(mockERC20), sendValue, "");

        // approve amount to gateway contract
        vm.prank(sender);
        mockERC20.approve(address(gateway), sendValueWithFees);

        // generate signature
        bytes32 _transactionId = keccak256("transaction ID");
        bytes memory _signature = _prepareAndSignData(
            123, // sign with random private key
            clientId,
            _transactionId,
            address(mockERC20),
            sendValue,
            address(mockTarget),
            targetCalldata
        );

        // send transaction
        vm.prank(sender);
        vm.expectRevert("failed to verify transaction");
        gateway.startTransfer(
            clientId,
            _transactionId,
            address(mockERC20),
            sendValue,
            payouts,
            payable(address(mockTarget)),
            targetCalldata,
            _signature
        );
    }
}
