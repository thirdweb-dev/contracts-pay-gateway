require("dotenv").config();
const { PRIVATE_KEY, CMC_API_KEY } = process.env || null;

require("@nomicfoundation/hardhat-toolbox");
require("hardhat-gas-reporter");
require("hardhat-contract-sizer");

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
      deployedThirdwebGatewayAddress:
        "0xB246b022df8cFd4a752dC058236Cc0A6abd02E3c",
      chainId: 137,
    },
    optimism: {
      url: "https://optimism-mainnet.public.blastapi.io",
      accounts: [PRIVATE_KEY],
      gasMultiplier: 2,
      chainId: 10,
    },
  },
  contractSizer: {
    alphaSort: true,
    disambiguatePaths: false,
    runOnCompile: true,
    strict: true,
    only: [":ThirdwebPaymentsGateway"],
  },
  gasReporter: {
    currency: "USD",
    enabled: true,
    //token: "Matic",
    coinmarketcap: [CMC_API_KEY],
  },
};
