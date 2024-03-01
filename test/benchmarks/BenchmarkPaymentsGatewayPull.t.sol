// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import { Test, console, console2 } from "forge-std/Test.sol";
import { PaymentsGatewayPull } from "src/PaymentsGatewayPull.sol";
import { MockERC20 } from "../utils/MockERC20.sol";
import { MockTarget } from "../utils/MockTarget.sol";

contract BenchmarkPaymentsGatewayPullTest is Test {
    PaymentsGatewayPull internal gateway;
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

    PaymentsGatewayPull.PayoutInfo[] internal payouts;

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

        ownerFeeBps = 200;
        clientFeeBps = 100;

        gateway = new PaymentsGatewayPull(owner, operator);
        mockERC20 = new MockERC20("Token", "TKN");
        mockTarget = new MockTarget();

        // fund the sender
        mockERC20.mint(sender, 10 ether);
        vm.deal(sender, 10 ether);

        // build payout info
        payouts.push(
            PaymentsGatewayPull.PayoutInfo({ clientId: ownerClientId, payoutAddress: owner, feeBPS: ownerFeeBps })
        );
        payouts.push(
            PaymentsGatewayPull.PayoutInfo({ clientId: clientId, payoutAddress: client, feeBPS: clientFeeBps })
        );
        for (uint256 i = 0; i < payouts.length; i++) {
            totalFeeBps += payouts[i].feeBPS;
        }

        // EIP712
        typehashPayoutInfo = keccak256("PayoutInfo(bytes32 clientId,address payoutAddress,uint256 feeBPS)");
        typehashPayRequest = keccak256(
            "PayRequest(bytes32 clientId,bytes32 transactionId,address tokenAddress,uint256 tokenAmount,PayoutInfo[] payouts)PayoutInfo(bytes32 clientId,address payoutAddress,uint256 feeBPS)"
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

    function _hashPayoutInfo(PaymentsGatewayPull.PayoutInfo[] memory _payouts) private view returns (bytes32) {
        // bytes32 payoutHash = keccak256(abi.encodePacked("PayoutInfo"));
        bytes32 payoutHash = typehashPayoutInfo;
        for (uint256 i = 0; i < _payouts.length; ++i) {
            payoutHash = keccak256(
                abi.encode(payoutHash, _payouts[i].clientId, _payouts[i].payoutAddress, _payouts[i].feeBPS)
            );
        }
        return payoutHash;
    }

    function _prepareAndSignData(
        uint256 _operatorPrivateKey,
        PaymentsGatewayPull.PayRequest memory req
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
                _payoutsHash,
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
        vm.pauseGasMetering();
        uint256 sendValue = 1 ether;
        uint256 sendValueWithFees = sendValue + (sendValue * totalFeeBps) / 10_000;
        bytes memory targetCalldata = _buildMockTargetCalldata(sender, receiver, address(mockERC20), sendValue, "");

        // approve amount to gateway contract
        vm.prank(sender);
        mockERC20.approve(address(gateway), sendValueWithFees);

        // create pay request
        PaymentsGatewayPull.PayRequest memory req;
        bytes32 _transactionId = keccak256("transaction ID");

        req.clientId = clientId;
        req.transactionId = _transactionId;
        req.tokenAddress = address(mockERC20);
        req.tokenAmount = sendValue;
        req.forwardAddress = payable(address(mockTarget));
        req.data = targetCalldata;
        req.payouts = payouts;

        // generate signature
        bytes memory _signature = _prepareAndSignData(
            2, // sign with operator private key, i.e. 2
            req
        );

        // send transaction
        vm.prank(sender);
        vm.resumeGasMetering();
        gateway.startTransfer(req, _signature);
    }

    function test_startTransfer_nativeToken() public {
        vm.pauseGasMetering();
        uint256 sendValue = 1 ether;
        uint256 sendValueWithFees = sendValue + (sendValue * totalFeeBps) / 10_000;
        bytes memory targetCalldata = _buildMockTargetCalldata(sender, receiver, address(0), sendValue, "");

        // create pay request
        PaymentsGatewayPull.PayRequest memory req;
        bytes32 _transactionId = keccak256("transaction ID");

        req.clientId = clientId;
        req.transactionId = _transactionId;
        req.tokenAddress = address(0);
        req.tokenAmount = sendValue;
        req.forwardAddress = payable(address(mockTarget));
        req.data = targetCalldata;
        req.payouts = payouts;

        // generate signature
        bytes memory _signature = _prepareAndSignData(
            2, // sign with operator private key, i.e. 2
            req
        );

        // send transaction
        vm.prank(sender);
        vm.resumeGasMetering();
        gateway.startTransfer{ value: sendValueWithFees }(req, _signature);
    }
}
