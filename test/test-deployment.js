const {
  loadFixture,
} = require("@nomicfoundation/hardhat-toolbox/network-helpers");
const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("Test Deployment", function () {
  async function deployContracts() {
    try {
      [owner, addr1, addr2, operator, payoutAddress] =
        await ethers.getSigners();

      // Deploy MockERC20
      const MockERC20 = await ethers.getContractFactory("MockERC20");
      mockERC20 = await MockERC20.deploy("Mock Token", "MTK");
      await mockERC20.waitForDeployment();

      // Deploy MockTarget
      const MockTarget = await ethers.getContractFactory("MockTarget");
      mockTarget = await MockTarget.deploy();
      await mockTarget.waitForDeployment();

      // Deploy ThirdwebPaymentsGateway
      const ThirdwebPaymentsGateway = await ethers.getContractFactory(
        "ThirdwebPaymentsGateway"
      );

      gateway = await ThirdwebPaymentsGateway.deploy(
        owner.address,
        operator.address
      );
      await gateway.waitForDeployment();

      return { gateway: gateway, erc20: mockERC20, target: mockTarget };
    } catch (e) {
      console.log(e);
      throw e;
    }
  }

  it("should deploy MockERC20 successfully", async function () {
    const { erc20 } = await loadFixture(deployContracts);
    expect(await erc20.getAddress()).to.properAddress;
  });

  it("should deploy MockTarget successfully", async function () {
    const { target } = await loadFixture(deployContracts);
    expect(await target.getAddress()).to.properAddress;
  });

  it("should deploy ThirdwebPaymentsGateway successfully", async function () {
    const { gateway } = await loadFixture(deployContracts);
    expect(await gateway.getAddress()).to.properAddress;
  });
});
