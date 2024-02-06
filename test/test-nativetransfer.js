const {
  loadFixture,
} = require("@nomicfoundation/hardhat-toolbox/network-helpers");
const { expect } = require("chai");
const { ethers } = require("hardhat");

const {
  getClientId,
  convertClientIdToBytes32,
  convertBytes32ToClientId,
  getThirdwebClientId,
  buildMockTargetCall,
} = require("./utils");

describe("Native Transfer Tests", function () {
  async function deployContracts() {
    try {
      [owner, client, sender, receiver] = await ethers.getSigners();

      // Deploy MockTarget
      const MockTarget = await ethers.getContractFactory("MockTarget");
      mockTarget = await MockTarget.deploy();
      await mockTarget.waitForDeployment();

      // Deploy ThirdwebPaymentsGateway
      const ThirdwebPaymentsGateway = await ethers.getContractFactory(
        "ThirdwebPaymentsGateway"
      );

      gateway = await ThirdwebPaymentsGateway.deploy(owner.address);
      await gateway.waitForDeployment();

      return {
        gateway: gateway,
        target: mockTarget,
        owner,
        client,
        sender,
        receiver,
      };
    } catch (e) {
      console.log(e);
      throw e;
    }
  }

  it("should successfully transfer eth", async function () {
    const { gateway, target, owner, client, sender, receiver } =
      await loadFixture(deployContracts);

    // todo: move setup into fixture
    const clientId = getClientId();
    const clientIdBytes = convertClientIdToBytes32(clientId);
    const twClientId = getThirdwebClientId();
    const twClientIdBytes = convertClientIdToBytes32(twClientId);

    const payouts = [
      {
        clientId: twClientIdBytes,
        payoutAddress: owner.address,
        feeBPS: BigInt(200), // 2%
      },
      {
        clientId: clientIdBytes,
        payoutAddress: client.address,
        feeBPS: BigInt(100), // 1%
      },
    ];

    const totalFeeBPS = payouts.reduce(
      (acc, payee) => acc + payee.feeBPS,
      BigInt(0)
    );

    const forwardAddress = await target.getAddress();
    const sendValue = ethers.parseEther("1.0");
    const sendValueWithFees =
      sendValue + (sendValue * totalFeeBPS) / BigInt(10_000);

    // build dummy forward call
    const transactionId = "tx1234";
    const message = "Hello world!";

    const data = buildMockTargetCall(
      sender.address,
      receiver.address,
      ethers.ZeroAddress,
      sendValue,
      message
    );

    // trakc init balances
    const initialOwnerBalance = await ethers.provider.getBalance(owner.address);
    const initialClientBalance = await ethers.provider.getBalance(
      client.address
    );
    const initialSenderBalance = await ethers.provider.getBalance(
      sender.address
    );
    const initialReceiverBalance = await ethers.provider.getBalance(
      receiver.address
    );

    const tx = await gateway
      .connect(sender)
      .startTransfer(
        clientIdBytes,
        transactionId,
        ethers.ZeroAddress,
        sendValue,
        payouts,
        forwardAddress,
        data,
        { value: sendValueWithFees }
      );
    const receipt = await tx.wait();
    expect(receipt, "transfer reverted").to.not.be.reverted;

    // get balances after transfer
    const finalOwnerBalance = await ethers.provider.getBalance(owner.address);
    const finalClientBalance = await ethers.provider.getBalance(client.address);
    const finalSenderBalance = await ethers.provider.getBalance(sender.address);
    const finalReceiverBalance = await ethers.provider.getBalance(
      receiver.address
    );

    // get gas cost
    const gasCost = receipt.gasUsed * receipt.gasPrice;

    // Assert the balance changes
    expect(finalOwnerBalance).to.equal(
      initialOwnerBalance + (sendValue * payouts[0].feeBPS) / BigInt(10_000),
      "unexpected owner balance"
    );

    expect(finalClientBalance).to.equal(
      initialClientBalance + (sendValue * payouts[1].feeBPS) / BigInt(10_000),
      "unexpected client balance"
    );

    expect(finalSenderBalance).to.equal(
      initialSenderBalance - sendValueWithFees - gasCost,
      "unexpected sender balance"
    );
    expect(finalReceiverBalance).to.equal(
      initialReceiverBalance + sendValue,
      "unexpected receiver balance"
    );
  });

  it("should successfully emit the transfer event", async function () {
    const { gateway, target, owner, client, sender, receiver } =
      await loadFixture(deployContracts);

    // todo: move setup into fixture
    const clientId = getClientId();
    const clientIdBytes = convertClientIdToBytes32(clientId);
    const twClientId = getThirdwebClientId();
    const twClientIdBytes = convertClientIdToBytes32(twClientId);

    const payouts = [
      {
        clientId: twClientIdBytes,
        payoutAddress: owner.address,
        feeBPS: BigInt(200), // 2%
      },
      {
        clientId: clientIdBytes,
        payoutAddress: client.address,
        feeBPS: BigInt(100), // 1%
      },
    ];

    const totalFeeBPS = payouts.reduce(
      (acc, payee) => acc + payee.feeBPS,
      BigInt(0)
    );

    const forwardAddress = await target.getAddress();
    const sendValue = ethers.parseEther("1.0");
    const sendValueWithFees =
      sendValue + (sendValue * totalFeeBPS) / BigInt(10_000);

    // build dummy forward call
    const transactionId = "tx1234";
    const message = "Hello world!";

    const data = buildMockTargetCall(
      sender.address,
      receiver.address,
      ethers.ZeroAddress,
      sendValue,
      message
    );

    await expect(
      gateway
        .connect(sender)
        .startTransfer(
          clientIdBytes,
          transactionId,
          ethers.ZeroAddress,
          sendValue,
          payouts,
          forwardAddress,
          data,
          { value: sendValueWithFees }
        )
    )
      .to.emit(gateway, "TransferStart")
      .withArgs(
        clientIdBytes,
        sender.address,
        transactionId,
        ethers.ZeroAddress,
        sendValue
      );
  });
});
