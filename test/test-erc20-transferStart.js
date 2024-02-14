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
  calcSendAmountWeiPostFees,
  generateSignature,
} = require("./utils");

describe("test:erc20:transferStart", function () {
  async function deployContracts() {
    try {
      [owner, client, sender, operator, receiver] = await ethers.getSigners();

      // Deploy erc20
      const MockERC20 = await ethers.getContractFactory("MockERC20");
      mockERC20 = await MockERC20.deploy("Mock Token", "MTK");
      await mockERC20.waitForDeployment();

      // fund the sender
      const tokenAmount = ethers.parseEther("10.0");
      const tx = await mockERC20.mint(sender.address, tokenAmount);
      await tx.wait();

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
        erc20: mockERC20,
        owner,
        client,
        sender,
        operator,
        receiver,
      };
    } catch (e) {
      console.log(e);
      throw e;
    }
  }

  it("should successfully transfer erc20", async function () {
    const { gateway, target, owner, erc20, client, sender, receiver } =
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
    const tokenAddress = await erc20.getAddress();
    const data = buildMockTargetCall(
      sender.address,
      receiver.address,
      tokenAddress,
      sendValue,
      message
    );

    // trakc init balances
    const initialOwnerBalance = await erc20.balanceOf(owner.address);
    const initialClientBalance = await erc20.balanceOf(client.address);
    const initialSenderBalance = await erc20.balanceOf(sender.address);
    const initialReceiverBalance = await erc20.balanceOf(receiver.address);

    // approve tw gateway contract
    const approveTx = await erc20
      .connect(sender)
      .approve(await gateway.getAddress(), sendValueWithFees);
    const approveReceipt = await approveTx.wait();
    expect(approveReceipt, "Approve Reverted").to.not.be.reverted;

    const signature = await prepareAndSignData(
      operator,
      {
        clientIdBytes,
        transactionIdBytes,
        tokenAddress,
        tokenAmount: sendValue,
        forwardAddress,
        data,
      },
      payouts
    );

    // send the transaction
    const tx = await gateway
      .connect(sender)
      .startTransfer(
        clientIdBytes,
        transactionIdBytes,
        tokenAddress,
        sendValue,
        payouts,
        forwardAddress,
        data,
        signature
      );
    const receipt = await tx.wait();
    expect(receipt, "transfer reverted").to.not.be.reverted;

    // get balances after transfer
    const finalOwnerBalance = await erc20.balanceOf(owner.address);
    const finalClientBalance = await erc20.balanceOf(client.address);
    const finalSenderBalance = await erc20.balanceOf(sender.address);
    const finalReceiverBalance = await erc20.balanceOf(receiver.address);

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
      initialSenderBalance - sendValueWithFees,
      "unexpected sender balance"
    );
    expect(finalReceiverBalance).to.equal(
      initialReceiverBalance + sendValue,
      "unexpected receiver balance"
    );
  });

  it("should successfully transfer erc20 .5 eth", async function () {
    const { gateway, target, owner, erc20, client, sender, receiver } =
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
    const sendValueWithFees = ethers.parseEther(".5");
    const sendValue = calcSendAmountWeiPostFees(sendValueWithFees, totalFeeBPS);

    // build dummy forward call
    const transactionIdBytes = convertUUIDToBytes32(getUUID());
    const message = "Hello world!";
    const tokenAddress = await erc20.getAddress();
    const data = buildMockTargetCall(
      sender.address,
      receiver.address,
      tokenAddress,
      sendValue,
      message
    );

    // trakc init balances
    const initialOwnerBalance = await erc20.balanceOf(owner.address);
    const initialClientBalance = await erc20.balanceOf(client.address);
    const initialSenderBalance = await erc20.balanceOf(sender.address);
    const initialReceiverBalance = await erc20.balanceOf(receiver.address);

    // approve tw gateway contract
    const approveTx = await erc20
      .connect(sender)
      .approve(await gateway.getAddress(), sendValueWithFees);
    const approveReceipt = await approveTx.wait();
    expect(approveReceipt, "Approve Reverted").to.not.be.reverted;

    const signature = await prepareAndSignData(
      operator,
      {
        clientIdBytes,
        transactionIdBytes,
        tokenAddress,
        tokenAmount: sendValue,
        forwardAddress,
        data,
      },
      payouts
    );

    // send the transaction
    const tx = await gateway
      .connect(sender)
      .startTransfer(
        clientIdBytes,
        transactionIdBytes,
        tokenAddress,
        sendValue,
        payouts,
        forwardAddress,
        data,
        signature
      );
    const receipt = await tx.wait();
    expect(receipt, "transfer reverted").to.not.be.reverted;

    // get balances after transfer
    const finalOwnerBalance = await erc20.balanceOf(owner.address);
    const finalClientBalance = await erc20.balanceOf(client.address);
    const finalSenderBalance = await erc20.balanceOf(sender.address);
    const finalReceiverBalance = await erc20.balanceOf(receiver.address);

    // Assert the balance changes
    expect(finalOwnerBalance).to.equal(
      initialOwnerBalance + (sendValue * payouts[0].feeBPS) / BigInt(10_000),
      "unexpected owner balance"
    );

    expect(finalClientBalance).to.equal(
      initialClientBalance + (sendValue * payouts[1].feeBPS) / BigInt(10_000),
      "unexpected client balance"
    );

    expect(finalSenderBalance).to.be.within(
      initialSenderBalance - sendValueWithFees - BigInt(3),
      initialSenderBalance - sendValueWithFees + BigInt(3),
      "unexpected sender balance"
    );

    expect(finalReceiverBalance).to.equal(
      initialReceiverBalance + sendValue,
      "unexpected receiver balance"
    );
  });

  it("should successfully emit events", async function () {
    const {
      gateway,
      target,
      owner,
      erc20,
      client,
      sender,
      operator,
      receiver,
    } = await loadFixture(deployContracts);

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
    const tokenAddress = await erc20.getAddress();
    const data = buildMockTargetCall(
      sender.address,
      receiver.address,
      tokenAddress,
      sendValue,
      message
    );

    // approve tw gateway contract
    const approveTx = await erc20
      .connect(sender)
      .approve(await gateway.getAddress(), sendValueWithFees);
    const approveReceipt = await approveTx.wait();
    expect(approveReceipt, "Approve Reverted").to.not.be.reverted;

    const signature = await prepareAndSignData(
      operator,
      {
        clientIdBytes,
        transactionIdBytes,
        tokenAddress,
        tokenAmount: sendValue,
        forwardAddress,
        data,
      },
      payouts
    );

    // send the transaction
    await expect(
      gateway
        .connect(sender)
        .startTransfer(
          clientIdBytes,
          transactionIdBytes,
          tokenAddress,
          sendValue,
          payouts,
          forwardAddress,
          data,
          signature
        )
    )
      .to.emit(gateway, "TransferStart")
      .withArgs(
        clientIdBytes,
        sender.address,
        transactionIdBytes,
        tokenAddress,
        sendValue
      );
  });

  it("should fail for invalid operator", async function () {
    const { gateway, target, owner, erc20, client, sender, receiver } =
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
    const tokenAddress = await erc20.getAddress();
    const data = buildMockTargetCall(
      sender.address,
      receiver.address,
      tokenAddress,
      sendValue,
      message
    );

    // approve tw gateway contract
    const approveTx = await erc20
      .connect(sender)
      .approve(await gateway.getAddress(), sendValueWithFees);
    const approveReceipt = await approveTx.wait();
    expect(approveReceipt, "Approve Reverted").to.not.be.reverted;

    const signature = await prepareAndSignData(
      sender,
      {
        clientIdBytes,
        transactionIdBytes,
        tokenAddress,
        tokenAmount: sendValue,
        forwardAddress,
        data,
      },
      payouts
    );

    // send the transaction
    await expect(
      gateway
        .connect(sender)
        .startTransfer(
          clientIdBytes,
          transactionIdBytes,
          tokenAddress,
          sendValue,
          payouts,
          forwardAddress,
          data,
          signature
        )
    ).to.be.revertedWith("failed to verify transaction");
  });
});
