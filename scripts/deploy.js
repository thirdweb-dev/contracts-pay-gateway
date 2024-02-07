// We require the Hardhat Runtime Environment explicitly here. This is optional
// but useful for running the script in a standalone fashion through `node <script>`.
//
// You can also run a script with `npx hardhat run <script>`. If you do that, Hardhat
// will compile your contracts, add the Hardhat Runtime Environment's members to the
// global scope, and execute the script.
const hre = require("hardhat");

async function main() {
  const signer = (await hre.ethers.getSigners())[0];

  const ThirdwebPaymentsGateway = await hre.ethers.getContractFactory(
    "ThirdwebPaymentsGateway"
  );
  const thirdwebPaymentsGateway = await ThirdwebPaymentsGateway.deploy(
    signer.address,
    signer.address
  );

  await thirdwebPaymentsGateway.waitForDeployment();

  console.log(`====== Successfully Deployed! ======`);
  console.log(`Deployed to: ${await thirdwebPaymentsGateway.getAddress()}`);
  console.log(`On chain: ${hre.network.config.chainId}`);
}

// We recommend this pattern to be able to use async/await everywhere
// and properly handle errors.
main()
  .then(() => process.exit(0))
  .catch((error) => {
    console.error(error);
    process.exit(1);
  });
