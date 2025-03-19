// SPDX-License-Identifier: Apache 2.0
pragma solidity ^0.8.0;

import { Test, console } from "forge-std/Test.sol";

import { PayGateway } from "src/PayGateway.sol";
import { PayGatewayModule } from "src/PayGatewayModule.sol";
import { IModuleConfig } from "lib/modular-contracts/src/interface/IModuleConfig.sol";
import { IModularCore } from "lib/modular-contracts/src/interface/IModularCore.sol";
import { LibClone } from "lib/solady/src/utils/LibClone.sol";
import { MockERC20 } from "./utils/MockERC20.sol";
import { MockTarget } from "./utils/MockTarget.sol";

contract PayGatewayTest is Test {
    event TokenPurchaseInitiated(
        bytes32 indexed clientId,
        address indexed sender,
        bytes32 transactionId,
        address tokenAddress,
        uint256 tokenAmount,
        bytes extraData
    );

    event OperatorChanged(address indexed previousOperator, address indexed newOperator);

    PayGatewayModule internal gateway;
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

    function setUp() public {
        owner = payable(vm.addr(1));
        operator = payable(vm.addr(2));
        sender = payable(vm.addr(3));
        receiver = payable(vm.addr(4));
        client = payable(vm.addr(5));

        ownerClientId = keccak256("owner");
        clientId = keccak256("client");

        ownerFeeBps = 20;
        clientFeeBps = 10;
        totalFeeBps = ownerFeeBps + clientFeeBps;

        // deploy and install module
        address module = address(new PayGatewayModule());

        address[] memory modules = new address[](1);
        bytes[] memory moduleData = new bytes[](1);
        modules[0] = address(module);
        moduleData[0] = "";

        gateway = PayGatewayModule(address(new PayGateway(operator, modules, moduleData)));

        mockERC20 = new MockERC20("Token", "TKN");
        mockTarget = new MockTarget();

        // fund the sender
        mockERC20.mint(sender, 10 ether);
        vm.deal(sender, 10 ether);

        vm.startPrank(operator);
        gateway.setFeeInfo(clientId, client, clientFeeBps);
        gateway.setOwnerFeeInfo(owner, ownerFeeBps);
        vm.stopPrank();
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

    /*///////////////////////////////////////////////////////////////
                    Test `initiateTokenPurchase`
    //////////////////////////////////////////////////////////////*/

    function test_initiateTokenPurchase_erc20() public {
        uint256 sendValue = 1 ether;
        uint256 ownerFee = (sendValue * ownerFeeBps) / 10_000;
        uint256 clientFee = (sendValue * clientFeeBps) / 10_000;
        uint256 sendValueWithFees = sendValue + ownerFee + clientFee;
        bytes memory targetCalldata = _buildMockTargetCalldata(sender, receiver, address(mockERC20), sendValue, "");

        // approve amount to gateway contract
        vm.prank(sender);
        mockERC20.approve(address(gateway), sendValueWithFees);

        bytes32 _transactionId = keccak256("transaction ID");

        // state/balances before sending transaction
        uint256 ownerBalanceBefore = mockERC20.balanceOf(owner);
        uint256 clientBalanceBefore = mockERC20.balanceOf(client);
        uint256 senderBalanceBefore = mockERC20.balanceOf(sender);
        uint256 receiverBalanceBefore = mockERC20.balanceOf(receiver);

        // send transaction
        vm.prank(sender);
        gateway.initiateTokenPurchase(
            clientId,
            _transactionId,
            address(mockERC20),
            sendValue,
            payable(address(mockTarget)),
            false,
            targetCalldata,
            ""
        );

        // check balances after transaction
        assertEq(mockERC20.balanceOf(owner), ownerBalanceBefore + ownerFee);
        assertEq(mockERC20.balanceOf(client), clientBalanceBefore + clientFee);
        assertEq(mockERC20.balanceOf(sender), senderBalanceBefore - sendValueWithFees);
        assertEq(mockERC20.balanceOf(receiver), receiverBalanceBefore + sendValue);
    }

    function test_initiateTokenPurchase_erc20_directTransfer() public {
        uint256 sendValue = 1 ether;
        uint256 ownerFee = (sendValue * ownerFeeBps) / 10_000;
        uint256 clientFee = (sendValue * clientFeeBps) / 10_000;
        uint256 sendValueWithFees = sendValue + ownerFee + clientFee;
        // bytes memory targetCalldata = abi.encodeWithSignature("transfer(address,uint256)", receiver, sendValue);

        // approve amount to gateway contract
        vm.prank(sender);
        mockERC20.approve(address(gateway), sendValueWithFees);

        bytes32 _transactionId = keccak256("transaction ID");

        // state/balances before sending transaction
        uint256 ownerBalanceBefore = mockERC20.balanceOf(owner);
        uint256 clientBalanceBefore = mockERC20.balanceOf(client);
        uint256 senderBalanceBefore = mockERC20.balanceOf(sender);
        uint256 receiverBalanceBefore = mockERC20.balanceOf(receiver);

        // send transaction
        vm.prank(sender);
        gateway.initiateTokenPurchase(
            clientId,
            _transactionId,
            address(mockERC20),
            sendValue,
            payable(address(receiver)),
            true,
            "",
            ""
        );

        // check balances after transaction
        assertEq(mockERC20.balanceOf(owner), ownerBalanceBefore + ownerFee);
        assertEq(mockERC20.balanceOf(client), clientBalanceBefore + clientFee);
        assertEq(mockERC20.balanceOf(sender), senderBalanceBefore - sendValueWithFees);
        assertEq(mockERC20.balanceOf(receiver), receiverBalanceBefore + sendValue);
    }

    function test_initiateTokenPurchase_nativeToken() public {
        uint256 sendValue = 1 ether;
        uint256 ownerFee = (sendValue * ownerFeeBps) / 10_000;
        uint256 clientFee = (sendValue * clientFeeBps) / 10_000;
        uint256 sendValueWithFees = sendValue + ownerFee + clientFee;
        bytes memory targetCalldata = _buildMockTargetCalldata(
            sender,
            receiver,
            address(0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE),
            sendValue,
            ""
        );

        bytes32 _transactionId = keccak256("transaction ID");

        // state/balances before sending transaction
        uint256 ownerBalanceBefore = owner.balance;
        uint256 clientBalanceBefore = client.balance;
        uint256 senderBalanceBefore = sender.balance;
        uint256 receiverBalanceBefore = receiver.balance;

        // send transaction
        vm.prank(sender);
        gateway.initiateTokenPurchase{ value: sendValueWithFees }(
            clientId,
            _transactionId,
            address(0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE),
            sendValue,
            payable(address(mockTarget)),
            false,
            targetCalldata,
            ""
        );

        // check balances after transaction
        assertEq(owner.balance, ownerBalanceBefore + ownerFee);
        assertEq(client.balance, clientBalanceBefore + clientFee);
        assertEq(sender.balance, senderBalanceBefore - sendValueWithFees);
        assertEq(receiver.balance, receiverBalanceBefore + sendValue);
    }

    function test_initiateTokenPurchase_nativeToken_directTransfer() public {
        uint256 sendValue = 1 ether;
        uint256 ownerFee = (sendValue * ownerFeeBps) / 10_000;
        uint256 clientFee = (sendValue * clientFeeBps) / 10_000;
        uint256 sendValueWithFees = sendValue + ownerFee + clientFee;
        bytes memory targetCalldata = "";

        bytes32 _transactionId = keccak256("transaction ID");

        // state/balances before sending transaction
        uint256 ownerBalanceBefore = owner.balance;
        uint256 clientBalanceBefore = client.balance;
        uint256 senderBalanceBefore = sender.balance;
        uint256 receiverBalanceBefore = receiver.balance;

        // send transaction
        vm.prank(sender);
        gateway.initiateTokenPurchase{ value: sendValueWithFees }(
            clientId,
            _transactionId,
            address(0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE),
            sendValue,
            payable(address(receiver)),
            true,
            targetCalldata,
            ""
        );

        // check balances after transaction
        assertEq(owner.balance, ownerBalanceBefore + ownerFee);
        assertEq(client.balance, clientBalanceBefore + clientFee);
        assertEq(sender.balance, senderBalanceBefore - sendValueWithFees);
        assertEq(receiver.balance, receiverBalanceBefore + sendValue);
    }

    function test_initiateTokenPurchase_events() public {
        uint256 sendValue = 1 ether;
        uint256 ownerFee = (sendValue * ownerFeeBps) / 10_000;
        uint256 clientFee = (sendValue * clientFeeBps) / 10_000;
        uint256 sendValueWithFees = sendValue + ownerFee + clientFee;
        bytes memory targetCalldata = _buildMockTargetCalldata(sender, receiver, address(mockERC20), sendValue, "");

        // approve amount to gateway contract
        vm.prank(sender);
        mockERC20.approve(address(gateway), sendValueWithFees);

        bytes32 _transactionId = keccak256("transaction ID");

        // send transaction
        vm.prank(sender);
        vm.expectEmit(true, true, false, true);
        emit TokenPurchaseInitiated(clientId, sender, _transactionId, address(mockERC20), sendValue, "");
        gateway.initiateTokenPurchase(
            clientId,
            _transactionId,
            address(mockERC20),
            sendValue,
            payable(address(mockTarget)),
            false,
            targetCalldata,
            ""
        );
    }
}
