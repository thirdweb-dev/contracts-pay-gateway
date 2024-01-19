require("dotenv").config();
const { PRIVATE_KEY } = process.env || null;

require("@nomicfoundation/hardhat-toolbox");

/** @type import('hardhat/config').HardhatUserConfig */
module.exports = {
  solidity: "0.8.22",

  networks: {
    mumbai: {
      url: "https://rpc-mumbai.maticvigil.com", // mumbai testnet
      accounts: [PRIVATE_KEY],
      gasMultiplier: 2,
      chainId: 80001,
    },
    polygon: {
      url: "https://polygon-rpc.com",
      accounts: [PRIVATE_KEY],
      gasMultiplier: 2,
      lifiContractAddress: "0x1231deb6f5749ef6ce6943a275a1d3e7486f4eae",
      chainId: 137,
    },
    optimism: {
      url: "https://optimism-mainnet.public.blastapi.io",
      accounts: [PRIVATE_KEY],
      gasMultiplier: 2,
      lifiContractAddress: "0x1231deb6f5749ef6ce6943a275a1d3e7486f4eae",
      chainId: 10,
    },
  },
};
