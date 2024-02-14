const { solidityPackedKeccak256, hashMessage } = require("ethers");
const { ethers } = require("hardhat");
const uuidv4 = require("uuid").v4;

const getUUID = () => {
  return uuidv4();
};

async function generateSignature(operator, dataToSign) {
  const signature = await operator.signMessage(
    ethers.utils.arrayify(dataToSign)
  );
  return signature;
}

function hashPayouts(payouts) {
  let payoutHash = ethers.id("PayoutInfo");
  payouts.forEach((payout) => {
    payoutHash = ethers.solidityPackedKeccak256(
      ["bytes32", "bytes32", "address", "uint256"],
      [payoutHash, payout.clientId, payout.payoutAddress, payout.feeBPS]
    );
  });
  return payoutHash;
}

async function prepareAndSignData(operator, params, payouts) {
  const payoutsHash = hashPayouts(payouts);

  const dataToHash = ethers.solidityPackedKeccak256(
    ["bytes32", "bytes32", "address", "uint256", "bytes32", "address", "bytes"],
    [
      params.clientIdBytes,
      params.transactionIdBytes,
      params.tokenAddress,
      params.tokenAmount.toString(),
      payoutsHash,
      params.forwardAddress,
      params.data,
    ]
  );

  const signature = await operator.signMessage(ethers.toBeArray(dataToHash));

  // const sig = ethers.Signature.from(signature);

  return signature;
}

// TODO: should probably zeroPadLeft
const convertUUIDToBytes32 = (uuid) => {
  const originalBytes = Buffer.from(uuid.replace(/-/g, ""), "hex");
  const paddedBuffer = Buffer.alloc(32);
  originalBytes.copy(paddedBuffer, 0);
  const uuidUint8Array = new Uint8Array(paddedBuffer);
  const uuidBytes = ethers.hexlify(uuidUint8Array);
  return uuidBytes;
};

const convertBytes32ToUUID = (UUIDBytes) => {
  let trimmedHex = ethers.stripZerosLeft(UUIDBytes);
  const uuidPattern = trimmedHex.replace(
    /^([\da-f]{8})([\da-f]{4})([\da-f]{4})([\da-f]{4})([\da-f]{12})$/,
    "$1-$2-$3-$4-$5"
  );

  return uuidPattern;
};

const calculateThirdwebSwapFees = (baseAmountWei, totalFeeBPS) => {
  return (baseAmountWei * totalFeeBPS) / BigInt(10_000);
};

const calcFromAmountWeiPostFees = (sendAmountWei, totalFeeBPS) => {
  return sendAmountWei + calculateThirdwebSwapFees(sendAmountWei, totalFeeBPS);
};

const calcSendAmountWeiPostFees = (fromAmountWei, totalFeeBPS) => {
  return (fromAmountWei * BigInt(10_000)) / (BigInt(10_000) + totalFeeBPS);
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
  getUUID,
  convertUUIDToBytes32,
  convertBytes32ToUUID,
  getThirdwebClientId,
  buildMockTargetCall,
  prepareAndSignData,
  generateSignature,
  calcSendAmountWeiPostFees,
  calculateThirdwebSwapFees,
};
