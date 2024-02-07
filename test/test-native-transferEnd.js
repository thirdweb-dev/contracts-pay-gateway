const {
  loadFixture,
} = require("@nomicfoundation/hardhat-toolbox/network-helpers");
const { expect } = require("chai");
const { ethers } = require("hardhat");

const { getUUID, convertUUIDToBytes32 } = require("./utils");

describe("test:native:transferEnd", function () {
  async function deployContracts() {
    try {
      [owner, client, sender, operator, receiver] = await ethers.getSigners();

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

  it("should successfully transfer native token", async function () {
    const { gateway, owner, sender, receiver } = await loadFixture(
      deployContracts
    );

    // todo: move setup into fixture
    const clientIdBytes = convertUUIDToBytes32(getUUID());
    const sendValue = ethers.parseEther("1.0");

    // trakc init balances
    const initialOwnerBalance = await ethers.provider.getBalance(owner.address);
    const initialSenderBalance = await ethers.provider.getBalance(
      sender.address
    );
    const initialReceiverBalance = await ethers.provider.getBalance(
      receiver.address
    );

    const transactionId = convertUUIDToBytes32(getUUID());

    // send the transaction
    const tx = await gateway
      .connect(sender)
      .endTransfer(
        clientIdBytes,
        transactionId,
        ethers.ZeroAddress,
        sendValue,
        receiver.address,
        { value: sendValue }
      );
    const receipt = await tx.wait();
    expect(receipt, "transfer reverted").to.not.be.reverted;

    // get gas cost
    const gasCost = receipt.gasUsed * receipt.gasPrice;

    // get balances after transfer
    const finalOwnerBalance = await ethers.provider.getBalance(owner.address);
    const finalSenderBalance = await ethers.provider.getBalance(sender.address);
    const finalReceiverBalance = await ethers.provider.getBalance(
      receiver.address
    );

    // Assert the balance changes
    expect(finalOwnerBalance).to.equal(
      initialOwnerBalance,
      "unexpected owner balance"
    );

    expect(finalSenderBalance).to.equal(
      initialSenderBalance - sendValue - gasCost,
      "unexpected sender balance"
    );
    expect(finalReceiverBalance).to.equal(
      initialReceiverBalance + sendValue,
      "unexpected receiver balance"
    );
  });

  it("should successfully emit events", async function () {
    const { gateway, sender, receiver } = await loadFixture(deployContracts);

    // todo: move setup into fixture
    const clientIdBytes = convertUUIDToBytes32(getUUID());
    const sendValue = ethers.parseEther("1.0");

    const transactionId = convertUUIDToBytes32(getUUID());

    await expect(
      await gateway
        .connect(sender)
        .endTransfer(
          clientIdBytes,
          transactionId,
          ethers.ZeroAddress,
          sendValue,
          receiver.address,
          { value: sendValue }
        )
    )
      .to.emit(gateway, "TransferEnd")
      .withArgs(
        clientIdBytes,
        receiver.address,
        transactionId,
        ethers.ZeroAddress,
        sendValue
      );
  });
});
