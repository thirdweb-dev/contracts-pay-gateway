const { ethers } = require("hardhat");
const uuidv4 = require("uuid").v4;

const getClientId = () => {
  return uuidv4();
};

// TODO: should probably zeroPadLeft
const convertClientIdToBytes32 = (clientId) => {
  const originalBytes = Buffer.from(clientId.replace(/-/g, ""), "hex");
  const paddedBuffer = Buffer.alloc(32);
  originalBytes.copy(paddedBuffer, 0);
  const clientIdUint8Array = new Uint8Array(paddedBuffer);
  const clientIdBytes = ethers.hexlify(clientIdUint8Array);
  return clientIdBytes;
};

const convertBytes32ToClientId = (clientIdBytes) => {
  let trimmedHex = ethers.stripZerosLeft(clientIdBytes);
  const uuidPattern = trimmedHex.replace(
    /^([\da-f]{8})([\da-f]{4})([\da-f]{4})([\da-f]{4})([\da-f]{12})$/,
    "$1-$2-$3-$4-$5"
  );

  return uuidPattern;
};

const getThirdwebClientId = () => {
  // all zeroes
  const paddedBuffer = Buffer.alloc(32);
  const clientIdUint8Array = new Uint8Array(paddedBuffer);
  const clientId = ethers.hexlify(clientIdUint8Array);
  return clientId;
};

const buildMockTargetCall = (
  senderAddress,
  receiverAddress,
  tokenAddress,
  sendValue,
  message
) => {
  const data = ethers.AbiCoder.defaultAbiCoder().encode(
    ["address", "address", "address", "uint256", "string"],
    [senderAddress, receiverAddress, tokenAddress, sendValue, message]
  );

  return data;
};

module.exports = {
  getClientId,
  convertClientIdToBytes32,
  convertBytes32ToClientId,
  getThirdwebClientId,
  buildMockTargetCall,
};
