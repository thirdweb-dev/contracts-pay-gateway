const {
  loadFixture,
} = require("@nomicfoundation/hardhat-toolbox/network-helpers");
const { expect } = require("chai");
const { ethers } = require("hardhat");

describe("ERC20 Transfer Tests", function () {
  async function deployContracts() {
    try {
      [owner, clientFrom, clientTo] = await ethers.getSigners();

      // Deploy erc20
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

      const feeBPS = BigInt(300);

      // mint to client
      const tokenAmount = ethers.parseEther("10.0");
      const tx = await mockERC20.mint(clientFrom.address, tokenAmount);
      await tx.wait();

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
        erc20: mockERC20,
        owner,
        clientFrom,
        clientTo,
        tokenAmount,
        feeBPS,
      };
    } catch (e) {
      console.log(e);
      throw e;
    }
  }

  it("should successfully transfer erc20", async function () {
    const {
      gateway,
      target,
      owner,
      erc20,
      tokenAmount,
      clientFrom,
      clientTo,
      feeBPS,
    } = await loadFixture(deployContracts);
    const txValue = ethers.parseEther("1.0");
    const feeAmount = (txValue * feeBPS) / BigInt(10000);
    const transactionId = "tx1234";
    const clientId = "client1234";
    const message = "Hello world!";
    const tokenAddress = await erc20.getAddress();
    console.log(`TokenAddress: ${tokenAddress}`);

    const data = target.interface.encodeFunctionData("performERC20Action", [
      tokenAddress,
      txValue - feeAmount,
      clientTo.address,
      message,
    ]);

    const initialOwnerBalance = await erc20.balanceOf(owner.address);
    const initialClientFromBalance = await erc20.balanceOf(clientFrom.address);
    const initialClientToBalance = await erc20.balanceOf(clientTo.address);

    const approveTx = await erc20
      .connect(clientFrom)
      .approve(await gateway.getAddress(), txValue);
    const approveReceipt = await approveTx.wait();
    expect(approveReceipt, "Approve Reverted").to.not.be.reverted;

    const tx = await gateway
      .connect(clientFrom)
      .erc20Transfer(clientId, transactionId, tokenAddress, txValue, data);
    const receipt = await tx.wait();
    expect(receipt, "transfer reverted").to.not.be.reverted;

    const finalOwnerBalance = await erc20.balanceOf(owner.address);
    const finalClientFromBalance = await erc20.balanceOf(clientFrom.address);
    const finalClientToBalance = await erc20.balanceOf(clientTo.address);

    // Calculate the expected fee and amount transferred to clientTo

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
      initialClientFromBalance - txValue,
      "unexpected fromClient erc20 balance"
    );
  });

  it("should successfully emit the transfer event", async function () {
    const {
      gateway,
      target,
      owner,
      erc20,
      tokenAmount,
      clientFrom,
      clientTo,
      feeBPS,
    } = await loadFixture(deployContracts);
    const txValue = ethers.parseEther("1.0");
    const feeAmount = (txValue * feeBPS) / BigInt(10000);
    const transactionId = "tx1234";
    const clientId = "client1234";
    const message = "Hello world!";
    const tokenAddress = await erc20.getAddress();
    console.log(`TokenAddress: ${tokenAddress}`);

    const data = target.interface.encodeFunctionData("performERC20Action", [
      tokenAddress,
      txValue - feeAmount,
      clientTo.address,
      message,
    ]);

    const approveTx = await erc20
      .connect(clientFrom)
      .approve(await gateway.getAddress(), txValue);
    const approveReceipt = await approveTx.wait();
    expect(approveReceipt, "Approve Reverted").to.not.be.reverted;

    await expect(
      gateway
        .connect(clientFrom)
        .erc20Transfer(clientId, transactionId, tokenAddress, txValue, data)
    )
      .to.emit(gateway, "ERC20TransferStart")
      .withArgs(
        clientId,
        transactionId,
        clientFrom.address,
        tokenAddress,
        txValue
      );

    const filter = target.filters.LogMessage(); // Replace 'LogMessage' with the actual event name
    const events = await target.queryFilter(filter);
    expect(events.length).to.be.greaterThan(0);
    expect(events[0].args.message).to.equal(message);
  });
});
