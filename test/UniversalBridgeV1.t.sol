// SPDX-License-Identifier: Apache 2.0
pragma solidity ^0.8.0;

import { Test, console } from "forge-std/Test.sol";

import { UniversalBridgeV1 } from "src/UniversalBridgeV1.sol";
import { UniversalBridgeProxy } from "src/UniversalBridgeProxy.sol";
import { IModuleConfig } from "lib/modular-contracts/src/interface/IModuleConfig.sol";
import { IModularCore } from "lib/modular-contracts/src/interface/IModularCore.sol";
import { LibClone } from "lib/solady/src/utils/LibClone.sol";
import { MockERC20 } from "./utils/MockERC20.sol";
import { MockTarget } from "./utils/MockTarget.sol";

contract UniversalBridgeTest is Test {
    event TransactionInitiated(
        address indexed sender,
        bytes32 indexed transactionId,
        address tokenAddress,
        uint256 tokenAmount,
        address developerFeeRecipient,
        uint256 developerFeeBps,
        bytes extraData
    );

    UniversalBridgeV1 internal bridge;
    MockERC20 internal mockERC20;
    MockTarget internal mockTarget;

    address payable internal owner;
    address payable internal protocolFeeRecipient;
    address payable internal sender;
    address payable internal receiver;
    address payable internal developer;

    uint256 internal protocolFeeBps;
    uint256 internal developerFeeBps;
    uint256 internal totalFeeBps;

    function setUp() public {
        owner = payable(vm.addr(1));
        protocolFeeRecipient = payable(vm.addr(2));
        sender = payable(vm.addr(3));
        receiver = payable(vm.addr(4));
        developer = payable(vm.addr(5));

        protocolFeeBps = 20;
        developerFeeBps = 10;
        totalFeeBps = protocolFeeBps + developerFeeBps;

        // deploy impl and proxy
        address impl = address(new UniversalBridgeV1());
        bridge = UniversalBridgeV1(
            address(new UniversalBridgeProxy(impl, owner, protocolFeeRecipient, protocolFeeBps))
        );

        mockERC20 = new MockERC20("Token", "TKN");
        mockTarget = new MockTarget();

        // fund the sender
        mockERC20.mint(sender, 10 ether);
        vm.deal(sender, 10 ether);
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
                    Test `initiateTransaction`
    //////////////////////////////////////////////////////////////*/

    function test_initiateTransaction_erc20() public {
        uint256 sendValue = 1 ether;
        uint256 protocolFee = (sendValue * protocolFeeBps) / 10_000;
        uint256 developerFee = (sendValue * developerFeeBps) / 10_000;
        uint256 sendValueWithFees = sendValue + protocolFee + developerFee;
        bytes memory targetCalldata = _buildMockTargetCalldata(sender, receiver, address(mockERC20), sendValue, "");

        // approve amount to bridge contract
        vm.prank(sender);
        mockERC20.approve(address(bridge), sendValueWithFees);

        bytes32 _transactionId = keccak256("transaction ID");

        // state/balances before sending transaction
        uint256 protocolFeeRecipientBalanceBefore = mockERC20.balanceOf(protocolFeeRecipient);
        uint256 developerBalanceBefore = mockERC20.balanceOf(developer);
        uint256 senderBalanceBefore = mockERC20.balanceOf(sender);
        uint256 receiverBalanceBefore = mockERC20.balanceOf(receiver);

        // send transaction
        vm.prank(sender);
        bridge.initiateTransaction(
            _transactionId,
            address(mockERC20),
            sendValue,
            payable(address(mockTarget)),
            developer,
            developerFeeBps,
            false,
            targetCalldata,
            ""
        );

        // check balances after transaction
        assertEq(mockERC20.balanceOf(protocolFeeRecipient), protocolFeeRecipientBalanceBefore + protocolFee);
        assertEq(mockERC20.balanceOf(developer), developerBalanceBefore + developerFee);
        assertEq(mockERC20.balanceOf(sender), senderBalanceBefore - sendValueWithFees);
        assertEq(mockERC20.balanceOf(receiver), receiverBalanceBefore + sendValue);
    }

    function test_initiateTransaction_erc20_directTransfer() public {
        uint256 sendValue = 1 ether;
        uint256 protocolFee = (sendValue * protocolFeeBps) / 10_000;
        uint256 developerFee = (sendValue * developerFeeBps) / 10_000;
        uint256 sendValueWithFees = sendValue + protocolFee + developerFee;
        // bytes memory targetCalldata = abi.encodeWithSignature("transfer(address,uint256)", receiver, sendValue);

        // approve amount to bridge contract
        vm.prank(sender);
        mockERC20.approve(address(bridge), sendValueWithFees);

        bytes32 _transactionId = keccak256("transaction ID");

        // state/balances before sending transaction
        uint256 protocolFeeRecipientBalanceBefore = mockERC20.balanceOf(protocolFeeRecipient);
        uint256 developerBalanceBefore = mockERC20.balanceOf(developer);
        uint256 senderBalanceBefore = mockERC20.balanceOf(sender);
        uint256 receiverBalanceBefore = mockERC20.balanceOf(receiver);

        // send transaction
        vm.prank(sender);
        bridge.initiateTransaction(
            _transactionId,
            address(mockERC20),
            sendValue,
            payable(address(receiver)),
            developer,
            developerFeeBps,
            true,
            "",
            ""
        );

        // check balances after transaction
        assertEq(mockERC20.balanceOf(protocolFeeRecipient), protocolFeeRecipientBalanceBefore + protocolFee);
        assertEq(mockERC20.balanceOf(developer), developerBalanceBefore + developerFee);
        assertEq(mockERC20.balanceOf(sender), senderBalanceBefore - sendValueWithFees);
        assertEq(mockERC20.balanceOf(receiver), receiverBalanceBefore + sendValue);
    }

    function test_initiateTransaction_nativeToken() public {
        uint256 sendValue = 1 ether;
        uint256 protocolFee = (sendValue * protocolFeeBps) / 10_000;
        uint256 developerFee = (sendValue * developerFeeBps) / 10_000;
        uint256 sendValueWithFees = sendValue + protocolFee + developerFee;
        bytes memory targetCalldata = _buildMockTargetCalldata(
            sender,
            receiver,
            address(0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE),
            sendValue,
            ""
        );

        bytes32 _transactionId = keccak256("transaction ID");

        // state/balances before sending transaction
        uint256 protocolFeeRecipientBalanceBefore = protocolFeeRecipient.balance;
        uint256 developerBalanceBefore = developer.balance;
        uint256 senderBalanceBefore = sender.balance;
        uint256 receiverBalanceBefore = receiver.balance;

        // send transaction
        vm.prank(sender);
        bridge.initiateTransaction{ value: sendValueWithFees }(
            _transactionId,
            address(0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE),
            sendValue,
            payable(address(mockTarget)),
            developer,
            developerFeeBps,
            false,
            targetCalldata,
            ""
        );

        // check balances after transaction
        assertEq(protocolFeeRecipient.balance, protocolFeeRecipientBalanceBefore + protocolFee);
        assertEq(developer.balance, developerBalanceBefore + developerFee);
        assertEq(sender.balance, senderBalanceBefore - sendValueWithFees);
        assertEq(receiver.balance, receiverBalanceBefore + sendValue);
    }

    function test_initiateTransaction_nativeToken_directTransfer() public {
        uint256 sendValue = 1 ether;
        uint256 protocolFee = (sendValue * protocolFeeBps) / 10_000;
        uint256 developerFee = (sendValue * developerFeeBps) / 10_000;
        uint256 sendValueWithFees = sendValue + protocolFee + developerFee;
        bytes memory targetCalldata = "";

        bytes32 _transactionId = keccak256("transaction ID");

        // state/balances before sending transaction
        uint256 protocolFeeRecipientBalanceBefore = protocolFeeRecipient.balance;
        uint256 developerBalanceBefore = developer.balance;
        uint256 senderBalanceBefore = sender.balance;
        uint256 receiverBalanceBefore = receiver.balance;

        // send transaction
        vm.prank(sender);
        bridge.initiateTransaction{ value: sendValueWithFees }(
            _transactionId,
            address(0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE),
            sendValue,
            payable(address(receiver)),
            developer,
            developerFeeBps,
            true,
            targetCalldata,
            ""
        );

        // check balances after transaction
        assertEq(protocolFeeRecipient.balance, protocolFeeRecipientBalanceBefore + protocolFee);
        assertEq(developer.balance, developerBalanceBefore + developerFee);
        assertEq(sender.balance, senderBalanceBefore - sendValueWithFees);
        assertEq(receiver.balance, receiverBalanceBefore + sendValue);
    }

    function test_initiateTransaction_events() public {
        uint256 sendValue = 1 ether;
        uint256 protocolFee = (sendValue * protocolFeeBps) / 10_000;
        uint256 developerFee = (sendValue * developerFeeBps) / 10_000;
        uint256 sendValueWithFees = sendValue + protocolFee + developerFee;
        bytes memory targetCalldata = _buildMockTargetCalldata(sender, receiver, address(mockERC20), sendValue, "");

        // approve amount to bridge contract
        vm.prank(sender);
        mockERC20.approve(address(bridge), sendValueWithFees);

        bytes32 _transactionId = keccak256("transaction ID");

        // send transaction
        vm.prank(sender);
        vm.expectEmit(true, true, false, true);
        emit TransactionInitiated(
            sender,
            _transactionId,
            address(mockERC20),
            sendValue,
            developer,
            developerFeeBps,
            ""
        );
        bridge.initiateTransaction(
            _transactionId,
            address(mockERC20),
            sendValue,
            payable(address(mockTarget)),
            developer,
            developerFeeBps,
            false,
            targetCalldata,
            ""
        );
    }

    function test_revert_paused() public {
        vm.prank(owner);
        bridge.pause(true);

        vm.prank(sender);
        vm.expectRevert(UniversalBridgeV1.UniversalBridgePaused.selector);
        bridge.initiateTransaction(
            bytes32(0),
            address(mockERC20),
            1,
            payable(address(receiver)),
            developer,
            developerFeeBps,
            true,
            "",
            ""
        );
    }

    function test_revert_restrictedForwardAddress() public {
        vm.prank(owner);
        bridge.restrictAddress(address(receiver), true);

        vm.prank(sender);
        vm.expectRevert(UniversalBridgeV1.UniversalBridgeRestrictedAddress.selector);
        bridge.initiateTransaction(
            bytes32(0),
            address(mockERC20),
            1,
            payable(address(receiver)),
            developer,
            developerFeeBps,
            true,
            "",
            ""
        );
    }

    function test_revert_restrictedTokenAddress() public {
        vm.prank(owner);
        bridge.restrictAddress(address(mockERC20), true);

        vm.prank(sender);
        vm.expectRevert(UniversalBridgeV1.UniversalBridgeRestrictedAddress.selector);
        bridge.initiateTransaction(
            bytes32(0),
            address(mockERC20),
            1,
            payable(address(receiver)),
            developer,
            developerFeeBps,
            true,
            "",
            ""
        );
    }
}
