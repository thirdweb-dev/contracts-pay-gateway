const {
  loadFixture,
} = require("@nomicfoundation/hardhat-toolbox/network-helpers");
const { expect } = require("chai");
const { ethers } = require("hardhat");

const { getClientId, convertClientIdToBytes32 } = require("./utils");

describe("test:erc20:transferEnd", function () {
  async function deployContracts() {
    try {
      [owner, client, sender, receiver] = await ethers.getSigners();

      // Deploy erc20
      const MockERC20 = await ethers.getContractFactory("MockERC20");
      mockERC20 = await MockERC20.deploy("Mock Token", "MTK");
      await mockERC20.waitForDeployment();

      // fund the sender
      const tokenAmount = ethers.parseEther("10.0");
      const tx = await mockERC20.mint(sender.address, tokenAmount);
      await tx.wait();

      // Deploy ThirdwebPaymentsGateway
      const ThirdwebPaymentsGateway = await ethers.getContractFactory(
        "ThirdwebPaymentsGateway"
      );

      gateway = await ThirdwebPaymentsGateway.deploy(owner.address);
      await gateway.waitForDeployment();

      return {
        gateway: gateway,
        erc20: mockERC20,
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

  it("should successfully transfer erc20", async function () {
    const { gateway, owner, erc20, sender, receiver } = await loadFixture(
      deployContracts
    );

    // todo: move setup into fixture
    const clientId = getClientId();
    const clientIdBytes = convertClientIdToBytes32(clientId);
    const tokenAddress = await erc20.getAddress();
    const sendValue = ethers.parseEther("1.0");

    // trakc init balances
    const initialOwnerBalance = await erc20.balanceOf(owner.address);
    const initialSenderBalance = await erc20.balanceOf(sender.address);
    const initialReceiverBalance = await erc20.balanceOf(receiver.address);

    const transactionId = "tx1234";

    // approve tw gateway contract
    const approveTx = await erc20
      .connect(sender)
      .approve(await gateway.getAddress(), sendValue);
    const approveReceipt = await approveTx.wait();
    expect(approveReceipt, "Approve Reverted").to.not.be.reverted;

    // send the transaction
    const tx = await gateway
      .connect(sender)
      .endTransfer(
        clientIdBytes,
        transactionId,
        tokenAddress,
        sendValue,
        receiver.address
      );
    const receipt = await tx.wait();
    expect(receipt, "transfer reverted").to.not.be.reverted;

    // get balances after transfer
    const finalOwnerBalance = await erc20.balanceOf(owner.address);
    const finalSenderBalance = await erc20.balanceOf(sender.address);
    const finalReceiverBalance = await erc20.balanceOf(receiver.address);

    // Assert the balance changes
    expect(finalOwnerBalance).to.equal(
      initialOwnerBalance,
      "unexpected owner balance"
    );

    expect(finalSenderBalance).to.equal(
      initialSenderBalance - sendValue,
      "unexpected sender balance"
    );
    expect(finalReceiverBalance).to.equal(
      initialReceiverBalance + sendValue,
      "unexpected receiver balance"
    );
  });

  it("should successfully emit events", async function () {
    const { gateway, erc20, sender, receiver } = await loadFixture(
      deployContracts
    );

    const clientId = getClientId();
    const clientIdBytes = convertClientIdToBytes32(clientId);

    const sendValue = ethers.parseEther("1.0");
    const tokenAddress = await erc20.getAddress();
    const transactionId = "tx1234";

    // approve tw gateway contract
    const approveTx = await erc20
      .connect(sender)
      .approve(await gateway.getAddress(), sendValue);
    const approveReceipt = await approveTx.wait();
    expect(approveReceipt, "Approve Reverted").to.not.be.reverted;

    await expect(
      await gateway
        .connect(sender)
        .endTransfer(
          clientIdBytes,
          transactionId,
          tokenAddress,
          sendValue,
          receiver.address
        )
    )
      .to.emit(gateway, "TransferEnd")
      .withArgs(
        clientIdBytes,
        receiver.address,
        transactionId,
        tokenAddress,
        sendValue
      );
  });
});
