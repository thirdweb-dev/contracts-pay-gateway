const {
  loadFixture,
} = require("@nomicfoundation/hardhat-toolbox/network-helpers");
const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("Native Transfer Tests", function () {
  async function deployContracts() {
    try {
      [owner, clientFrom, clientTo] = await ethers.getSigners();

      // Deploy MockTarget
      const MockTarget = await ethers.getContractFactory("MockTarget");
      mockTarget = await MockTarget.deploy();
      await mockTarget.waitForDeployment();

      // Deploy ThirdwebPaymentsGateway
      const ThirdwebPaymentsGateway = await ethers.getContractFactory(
        "ThirdwebPaymentsGateway"
      );

      const feeBPS = BigInt(300);

      gateway = await ThirdwebPaymentsGateway.deploy(
        owner.address,
        owner.address,
        await mockTarget.getAddress(),
        feeBPS
      );
      await gateway.waitForDeployment();

      return {
        gateway: gateway,
        target: mockTarget,
        owner,
        clientFrom,
        clientTo,
        feeBPS,
      };
    } catch (e) {
      console.log(e);
      throw e;
    }
  }

  it("should successfully transfer eth", async function () {
    const { gateway, target, owner, clientFrom, clientTo, feeBPS } =
      await loadFixture(deployContracts);

    const txValue = ethers.parseEther("1.0");
    const transactionId = "tx1234";
    const clientId = "client1234";
    const message = "Hello world!";

    const data = target.interface.encodeFunctionData(
      "performNativeTokenAction",
      [clientTo.address, message]
    );

    const initialOwnerBalance = await ethers.provider.getBalance(owner.address);
    const initialClientFromBalance = await ethers.provider.getBalance(
      clientFrom.address
    );
    const initialClientToBalance = await ethers.provider.getBalance(
      clientTo.address
    );

    const tx = await gateway
      .connect(clientFrom)
      .nativeTransfer(clientId, transactionId, data, { value: txValue });
    const receipt = await tx.wait();

    const finalOwnerBalance = await ethers.provider.getBalance(owner.address);
    const finalClientFromBalance = await ethers.provider.getBalance(
      clientFrom.address
    );
    const finalClientToBalance = await ethers.provider.getBalance(
      clientTo.address
    );

    // get gas cost
    const gasCost = receipt.gasUsed * receipt.gasPrice;

    // Calculate the expected fee and amount transferred to clientTo
    const feeAmount = (txValue * feeBPS) / BigInt(10000);
    const expectedClientToBalance =
      initialClientToBalance + (txValue - feeAmount);

    // Assert the balance changes
    expect(finalOwnerBalance).to.equal(
      initialOwnerBalance + feeAmount,
      "unexpected owner balance"
    );
    expect(finalClientToBalance).to.equal(
      expectedClientToBalance,
      "unexpected toClient balance"
    );
    expect(finalClientFromBalance).to.equal(
      initialClientFromBalance - txValue - gasCost,
      "unexpected fromClient balance"
    );
  });

  it("should successfully emit the transfer event", async function () {
    const { gateway, target, owner, clientFrom, clientTo } = await loadFixture(
      deployContracts
    );

    const txValue = ethers.parseEther("1.0");
    const transactionId = "tx1234";
    const clientId = "client1234";
    const message = "Hello world!";

    const data = target.interface.encodeFunctionData(
      "performNativeTokenAction",
      [clientTo.address, message]
    );

    await expect(
      gateway
        .connect(clientFrom)
        .nativeTransfer(clientId, transactionId, data, { value: txValue })
    )
      .to.emit(gateway, "NativeTransferStart")
      .withArgs(clientId, transactionId, clientFrom.address);

    const filter = target.filters.LogMessage(); // Replace 'LogMessage' with the actual event name
    const events = await target.queryFilter(filter);
    expect(events.length).to.be.greaterThan(0);
    expect(events[0].args.message).to.equal(message);
  });
});
