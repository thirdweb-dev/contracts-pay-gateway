const {
  loadFixture,
} = require("@nomicfoundation/hardhat-toolbox/network-helpers");
const { expect } = require("chai");
const { ethers } = require("hardhat");

const {
  getUUID,
  convertUUIDToBytes32,
  getThirdwebClientId,
  buildMockTargetCall,
  prepareAndSignData,
} = require("./utils");

describe("test:native:transferStart", function () {
  async function deployContracts() {
    try {
      [owner, client, sender, operator, receiver] = await ethers.getSigners();

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

      return {
        gateway: gateway,
        target: mockTarget,
        owner,
        client,
        operator,
        sender,
        receiver,
      };
    } catch (e) {
      console.log(e);
      throw e;
    }
  }

  it("should successfully transfer eth", async function () {
    const { gateway, target, owner, client, sender, operator, receiver } =
      await loadFixture(deployContracts);

    // todo: move setup into fixture
    const clientIdBytes = convertUUIDToBytes32(getUUID());
    const twClientId = getThirdwebClientId();
    const twClientIdBytes = convertUUIDToBytes32(twClientId);

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
    const transactionIdBytes = convertUUIDToBytes32(getUUID());
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

    const signature = await prepareAndSignData(
      operator,
      {
        clientIdBytes,
        transactionIdBytes,
        tokenAddress: ethers.ZeroAddress,
        tokenAmount: sendValue,
        forwardAddress,
        data,
      },
      payouts
    );

    const tx = await gateway
      .connect(sender)
      .startTransfer(
        clientIdBytes,
        transactionIdBytes,
        ethers.ZeroAddress,
        sendValue,
        payouts,
        forwardAddress,
        data,
        signature,
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
    const { gateway, target, owner, client, sender, operator, receiver } =
      await loadFixture(deployContracts);

    // todo: move setup into fixture
    const clientIdBytes = convertUUIDToBytes32(getUUID());
    const twClientId = getThirdwebClientId();
    const twClientIdBytes = convertUUIDToBytes32(twClientId);

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
    const transactionIdBytes = convertUUIDToBytes32(getUUID());
    const message = "Hello world!";

    const data = buildMockTargetCall(
      sender.address,
      receiver.address,
      ethers.ZeroAddress,
      sendValue,
      message
    );

    const signature = await prepareAndSignData(
      operator,
      {
        clientIdBytes,
        transactionIdBytes,
        tokenAddress: ethers.ZeroAddress,
        tokenAmount: sendValue,
        forwardAddress,
        data,
      },
      payouts
    );

    await expect(
      gateway
        .connect(sender)
        .startTransfer(
          clientIdBytes,
          transactionIdBytes,
          ethers.ZeroAddress,
          sendValue,
          payouts,
          forwardAddress,
          data,
          signature,
          { value: sendValueWithFees }
        )
    )
      .to.emit(gateway, "TransferStart")
      .withArgs(
        clientIdBytes,
        sender.address,
        transactionIdBytes,
        ethers.ZeroAddress,
        sendValue
      );
  });

  it("should fail for invalid operator", async function () {
    const { gateway, target, owner, client, sender, operator, receiver } =
      await loadFixture(deployContracts);

    // todo: move setup into fixture
    const clientIdBytes = convertUUIDToBytes32(getUUID());
    const twClientId = getThirdwebClientId();
    const twClientIdBytes = convertUUIDToBytes32(twClientId);

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
    const transactionIdBytes = convertUUIDToBytes32(getUUID());
    const message = "Hello world!";

    const data = buildMockTargetCall(
      sender.address,
      receiver.address,
      ethers.ZeroAddress,
      sendValue,
      message
    );

    const signature = await prepareAndSignData(
      owner,
      {
        clientIdBytes,
        transactionIdBytes,
        tokenAddress: ethers.ZeroAddress,
        tokenAmount: sendValue,
        forwardAddress,
        data,
      },
      payouts
    );

    await expect(
      gateway
        .connect(sender)
        .startTransfer(
          clientIdBytes,
          transactionIdBytes,
          ethers.ZeroAddress,
          sendValue,
          payouts,
          forwardAddress,
          data,
          signature,
          { value: sendValueWithFees }
        )
    ).to.be.revertedWith("failed to verify transaction");
  });
});
