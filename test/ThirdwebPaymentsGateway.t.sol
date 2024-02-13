// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.13;

import { Test, console2 } from "forge-std/Test.sol";
import { ThirdwebPaymentsGateway } from "contracts/ThirdwebPaymentsGateway.sol";
import { MockERC20 } from "./utils/MockERC20.sol";
import { MockTarget } from "./utils/MockTarget.sol";

contract ThirdwebPaymentsGatewayTest is Test {
    ThirdwebPaymentsGateway internal gateway;
    MockERC20 internal mockERC20;
    MockTarget internal mockTarget;

    address internal owner;
    address internal operator;

    function setUp() public {
        owner = address(0x123);
        operator = address(0x456);

        gateway = new ThirdwebPaymentsGateway(owner, operator);
        mockERC20 = new MockERC20("Token", "TKN");
        mockTarget = new MockTarget();
    }
}
