// Import ethers from Hardhat package
const { ethers } = require("hardhat");

async function main() {
  const signer = (await hre.ethers.getSigners())[0];

  if (!hre.network.config.deployedThirdwebGatewayAddress) {
    console.error("thirdweb gateway address not deployed on the network");
    return;
  }

  const feeBPS = BigInt(300); // 3% take

  const numFilterBlocks = 1000;
  const currentBlock = await ethers.provider.getBlockNumber(); // Current block number

  const ThirdwebPaymentsGateway = await ethers.getContractFactory(
    "ThirdwebPaymentsGateway"
  );
  // Attach to the deployed contract
  const thirdwebPaymentsGateway = ThirdwebPaymentsGateway.attach(
    hre.network.config.deployedThirdwebGatewayAddress
  );

  const filter = thirdwebPaymentsGateway.filters.ERC20TransferStart();

  const events = await thirdwebPaymentsGateway.queryFilter(
    filter,
    currentBlock - numFilterBlocks,
    currentBlock
  );

  if (events.length === 0) {
    console.log("No events found");
  } else {
    events.forEach((event) => {
      console.log("Event Args:", event.args);
      // Add any specific decoding or processing here
    });
  }
}

main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
