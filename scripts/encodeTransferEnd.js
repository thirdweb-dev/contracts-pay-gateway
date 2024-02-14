// Import ethers from Hardhat package
const { ethers } = require("hardhat");
const { getThirdwebClientId } = require("../test/utils");

async function main() {
  const signer = (await hre.ethers.getSigners())[0];

  if (!hre.network.config.deployedThirdwebGatewayAddress) {
    console.error("thirdweb gateway address not deployed on the network");
    return;
  }

  const ThirdwebPaymentsGateway = await ethers.getContractFactory(
    "ThirdwebPaymentsGateway"
  );

  // Attach to the deployed contract
  const thirdwebPaymentsGateway = ThirdwebPaymentsGateway.attach(
    hre.network.config.deployedThirdwebGatewayAddress
  );

  const txData = await thirdwebPaymentsGateway.endTransfer.populateTransaction(
    getThirdwebClientId(), /// dummy clientId
    getThirdwebClientId(), // dummy transactionId
    "0x7f5c764cbc14f9669b88837ca1490cca17c31607",
    10000000,
    "0xeBfb127320fcBe8e07E5A03a4BFb782219f4735B"
  );

  console.log(txData);
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
