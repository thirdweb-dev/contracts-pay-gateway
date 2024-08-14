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
        uint256 tokenAmount
    );

    event TokenPurchaseCompleted(
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

    uint256 internal ownerFeeAmount;
    uint256 internal clientFeeAmount;
    uint256 internal totalFeeAmount;

    PayGatewayModule.PayoutInfo[] internal payouts;

    bytes32 internal typehashPayRequest;
    bytes32 internal typehashPayoutInfo;
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

        ownerClientId = keccak256("owner");
        clientId = keccak256("client");

        ownerFeeAmount = 20;
        clientFeeAmount = 10;

        // deploy and install module
        address impl = address(new PayGateway());
        address module = address(new PayGatewayModule());

        address[] memory modules = new address[](1);
        bytes[] memory moduleData = new bytes[](1);
        modules[0] = address(module);
        moduleData[0] = "";

        gateway = PayGatewayModule(LibClone.clone(impl));
        PayGateway(payable(address(gateway))).initialize(operator, modules, moduleData);

        mockERC20 = new MockERC20("Token", "TKN");
        mockTarget = new MockTarget();

        // fund the sender
        mockERC20.mint(sender, 10 ether);
        vm.deal(sender, 10 ether);

        // build payout info
        payouts.push(
            PayGatewayModule.PayoutInfo({ clientId: ownerClientId, payoutAddress: owner, feeAmount: ownerFeeAmount })
        );
        payouts.push(
            PayGatewayModule.PayoutInfo({ clientId: clientId, payoutAddress: client, feeAmount: clientFeeAmount })
        );

        for (uint256 i = 0; i < payouts.length; i++) {
            totalFeeAmount += payouts[i].feeAmount;
        }

        // EIP712
        typehashPayoutInfo = keccak256("PayoutInfo(bytes32 clientId,address payoutAddress,uint256 feeAmount)");
        typehashPayRequest = keccak256(
            "PayRequest(bytes32 clientId,bytes32 transactionId,address tokenAddress,uint256 tokenAmount,uint256 expirationTimestamp,PayoutInfo[] payouts,address forwardAddress,bytes data)PayoutInfo(bytes32 clientId,address payoutAddress,uint256 feeAmount)"
        );
        nameHash = keccak256(bytes("PayGateway"));
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

    function _hashPayoutInfo(PayGatewayModule.PayoutInfo[] memory _payouts) private view returns (bytes32) {
        bytes32 payoutHash = typehashPayoutInfo;

        bytes32[] memory payoutsHashes = new bytes32[](_payouts.length);
        for (uint i = 0; i < payouts.length; i++) {
            payoutsHashes[i] = keccak256(
                abi.encode(payoutHash, _payouts[i].clientId, _payouts[i].payoutAddress, _payouts[i].feeAmount)
            );
        }
        return keccak256(abi.encodePacked(payoutsHashes));
    }

    function _prepareAndSignData(
        uint256 _operatorPrivateKey,
        PayGatewayModule.PayRequest memory req
    ) internal view returns (bytes memory signature) {
        bytes memory dataToHash;
        {
            bytes32 _payoutsHash = _hashPayoutInfo(req.payouts);
            dataToHash = abi.encode(
                typehashPayRequest,
                req.clientId,
                req.transactionId,
                req.tokenAddress,
                req.tokenAmount,
                req.expirationTimestamp,
                _payoutsHash,
                req.forwardAddress,
                keccak256(req.data)
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
                    Test `initiateTokenPurchase`
    //////////////////////////////////////////////////////////////*/

    function test_initiateTokenPurchase_erc20() public {
        uint256 sendValue = 1 ether;
        uint256 sendValueWithFees = sendValue + totalFeeAmount;
        bytes memory targetCalldata = _buildMockTargetCalldata(sender, receiver, address(mockERC20), sendValue, "");

        // approve amount to gateway contract
        vm.prank(sender);
        mockERC20.approve(address(gateway), sendValueWithFees);

        // create pay request
        PayGatewayModule.PayRequest memory req;
        bytes32 _transactionId = keccak256("transaction ID");

        req.clientId = clientId;
        req.transactionId = _transactionId;
        req.tokenAddress = address(mockERC20);
        req.tokenAmount = sendValue;
        req.forwardAddress = payable(address(mockTarget));
        req.expirationTimestamp = 1000;
        req.data = targetCalldata;
        req.payouts = payouts;

        // generate signature
        bytes memory _signature = _prepareAndSignData(
            2, // sign with operator private key, i.e. 2
            req
        );

        // state/balances before sending transaction
        uint256 ownerBalanceBefore = mockERC20.balanceOf(owner);
        uint256 clientBalanceBefore = mockERC20.balanceOf(client);
        uint256 senderBalanceBefore = mockERC20.balanceOf(sender);
        uint256 receiverBalanceBefore = mockERC20.balanceOf(receiver);

        // send transaction
        vm.prank(sender);
        gateway.initiateTokenPurchase(req, _signature);

        // check balances after transaction
        assertEq(mockERC20.balanceOf(owner), ownerBalanceBefore + ownerFeeAmount);
        assertEq(mockERC20.balanceOf(client), clientBalanceBefore + clientFeeAmount);
        assertEq(mockERC20.balanceOf(sender), senderBalanceBefore - sendValueWithFees);
        assertEq(mockERC20.balanceOf(receiver), receiverBalanceBefore + sendValue);
    }

    function test_initiateTokenPurchase_nativeToken() public {
        uint256 sendValue = 1 ether;
        uint256 sendValueWithFees = sendValue + totalFeeAmount;
        bytes memory targetCalldata = _buildMockTargetCalldata(
            sender,
            receiver,
            address(0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE),
            sendValue,
            ""
        );

        // create pay request
        PayGatewayModule.PayRequest memory req;
        bytes32 _transactionId = keccak256("transaction ID");

        req.clientId = clientId;
        req.transactionId = _transactionId;
        req.tokenAddress = address(0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE);
        req.tokenAmount = sendValue;
        req.forwardAddress = payable(address(mockTarget));
        req.expirationTimestamp = 1000;
        req.data = targetCalldata;
        req.payouts = payouts;

        console.logBytes32(clientId);
        console.logBytes32(_transactionId);
        console.log(sendValue);
        console.log(address(mockTarget));
        console.logBytes(targetCalldata);

        // generate signature
        bytes memory _signature = _prepareAndSignData(
            2, // sign with operator private key, i.e. 2
            req
        );

        // state/balances before sending transaction
        uint256 ownerBalanceBefore = owner.balance;
        uint256 clientBalanceBefore = client.balance;
        uint256 senderBalanceBefore = sender.balance;
        uint256 receiverBalanceBefore = receiver.balance;

        // send transaction
        vm.prank(sender);
        gateway.initiateTokenPurchase{ value: sendValueWithFees }(req, _signature);

        // check balances after transaction
        assertEq(owner.balance, ownerBalanceBefore + ownerFeeAmount);
        assertEq(client.balance, clientBalanceBefore + clientFeeAmount);
        assertEq(sender.balance, senderBalanceBefore - sendValueWithFees);
        assertEq(receiver.balance, receiverBalanceBefore + sendValue);
    }

    function test_initiateTokenPurchase_events() public {
        uint256 sendValue = 1 ether;
        uint256 sendValueWithFees = sendValue + totalFeeAmount;
        bytes memory targetCalldata = _buildMockTargetCalldata(sender, receiver, address(mockERC20), sendValue, "");

        // approve amount to gateway contract
        vm.prank(sender);
        mockERC20.approve(address(gateway), sendValueWithFees);

        // create pay request
        PayGatewayModule.PayRequest memory req;
        bytes32 _transactionId = keccak256("transaction ID");

        req.clientId = clientId;
        req.transactionId = _transactionId;
        req.tokenAddress = address(mockERC20);
        req.tokenAmount = sendValue;
        req.forwardAddress = payable(address(mockTarget));
        req.expirationTimestamp = 1000;
        req.data = targetCalldata;
        req.payouts = payouts;

        // generate signature
        bytes memory _signature = _prepareAndSignData(
            2, // sign with operator private key, i.e. 2
            req
        );

        // send transaction
        vm.prank(sender);
        vm.expectEmit(true, true, false, true);
        emit TokenPurchaseInitiated(req.clientId, sender, _transactionId, req.tokenAddress, req.tokenAmount);
        gateway.initiateTokenPurchase(req, _signature);
    }

    function test_revert_initiateTokenPurchase_invalidSignature() public {
        uint256 sendValue = 1 ether;
        uint256 sendValueWithFees = sendValue + totalFeeAmount;
        bytes memory targetCalldata = _buildMockTargetCalldata(sender, receiver, address(mockERC20), sendValue, "");

        // approve amount to gateway contract
        vm.prank(sender);
        mockERC20.approve(address(gateway), sendValueWithFees);

        // create pay request
        PayGatewayModule.PayRequest memory req;
        bytes32 _transactionId = keccak256("transaction ID");

        req.clientId = clientId;
        req.transactionId = _transactionId;
        req.tokenAddress = address(mockERC20);
        req.tokenAmount = sendValue;
        req.forwardAddress = payable(address(mockTarget));
        req.expirationTimestamp = 1000;
        req.data = targetCalldata;
        req.payouts = payouts;

        // generate signature
        bytes memory _signature = _prepareAndSignData(
            123, // sign with random private key
            req
        );

        // send transaction
        vm.prank(sender);
        vm.expectRevert(abi.encodeWithSelector(PayGatewayModule.PayGatewayVerificationFailed.selector));
        gateway.initiateTokenPurchase(req, _signature);
    }

    function test_revert_initiateTokenPurchase_requestExpired() public {
        uint256 sendValue = 1 ether;
        bytes memory targetCalldata = "";

        // create pay request
        PayGatewayModule.PayRequest memory req;
        bytes32 _transactionId = keccak256("transaction ID");

        req.clientId = clientId;
        req.transactionId = _transactionId;
        req.tokenAddress = address(mockERC20);
        req.tokenAmount = sendValue;
        req.forwardAddress = payable(address(mockTarget));
        req.expirationTimestamp = 1000;
        req.data = targetCalldata;
        req.payouts = payouts;

        // generate signature
        bytes memory _signature = _prepareAndSignData(2, req);

        vm.warp(req.expirationTimestamp + 1);
        // send transaction
        vm.prank(sender);
        vm.expectRevert(
            abi.encodeWithSelector(PayGatewayModule.PayGatewayRequestExpired.selector, req.expirationTimestamp)
        );
        gateway.initiateTokenPurchase(req, _signature);
    }

    // /*///////////////////////////////////////////////////////////////
    //                 Test `completeTokenPurchase`
    // //////////////////////////////////////////////////////////////*/

    function test_completeTokenPurchase_erc20() public {
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
        gateway.completeTokenPurchase(clientId, _transactionId, address(mockERC20), sendValue, receiver);

        // check balances after transaction
        assertEq(mockERC20.balanceOf(owner), ownerBalanceBefore);
        assertEq(mockERC20.balanceOf(sender), senderBalanceBefore - sendValue);
        assertEq(mockERC20.balanceOf(receiver), receiverBalanceBefore + sendValue);
    }

    function test_completeTokenPurchase_nativeToken() public {
        uint256 sendValue = 1 ether;

        // state/balances before sending transaction
        uint256 ownerBalanceBefore = owner.balance;
        uint256 senderBalanceBefore = sender.balance;
        uint256 receiverBalanceBefore = receiver.balance;

        // send transaction
        bytes32 _transactionId = keccak256("transaction ID");
        vm.prank(sender);
        gateway.completeTokenPurchase{ value: sendValue }(
            clientId,
            _transactionId,
            address(0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE),
            sendValue,
            receiver
        );

        // check balances after transaction
        assertEq(owner.balance, ownerBalanceBefore);
        assertEq(sender.balance, senderBalanceBefore - sendValue);
        assertEq(receiver.balance, receiverBalanceBefore + sendValue);
    }

    function test_completeTokenPurchase_events() public {
        uint256 sendValue = 1 ether;

        // approve amount to gateway contract
        vm.prank(sender);
        mockERC20.approve(address(gateway), sendValue);

        // send transaction
        bytes32 _transactionId = keccak256("transaction ID");
        vm.prank(sender);
        vm.expectEmit(true, true, false, true);
        emit TokenPurchaseCompleted(clientId, receiver, _transactionId, address(mockERC20), sendValue);
        gateway.completeTokenPurchase(clientId, _transactionId, address(mockERC20), sendValue, receiver);
    }
}
