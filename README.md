## **Thirdweb Gateway Contract**

Thirdweb Gateway Contract is used as the entrypoint to thirdweb Pay for swaps and bridges.

This is a forwarder contract that forwards the swap providers transaction (LiFi, Decent, etc) to their contract. Thirdweb Gateway Contract has the following responsibilities:

- Data Logging - this is essential for attribution and linking on-chain and off-chain data
- Fee Splitting - this allows us to split the fees in-flight and flexibility to change fees on a per client basis
- Data validation - this provides high-security as only thirdweb originated swaps with untampered data can use this contract
- exit point for contract calls - for LiFi, they can only guarantee toAmount for contract calls. This allows use to add a contract call to transferEnd that forwards the end funds to the user
- Stateless - this will be deployed on many different chains. We don’t want to have to call addClient, changeFee, addSwapProvider, etc on every single chain for every change. Therefore, this should not rely on data held in the state of the contract, but rather data passed in

[Thirdweb Gateway Reference](img/gateway.png)

[Thirdweb Gateway With Transfer End](img/gateway-transfer-end.png)

## Features

- Event Logging
  - TransferStart logs the necessary events attribution and link off-chain and on-chain through clientId and transactionId. We use bytes32 instead of string for clientId and transactionId (uuid in database) because this allows recovering indexed pre-image
  - TransferEnd logs the transfer end in case of a contract call and can be used for indexing bridge transactions by just listening to our Thirdweb Gateway deployments
  - FeePayout logs the fees distributed among the payees
- Fee Splitting
  - supports many parties for fee payouts (we only expect us and client). It also allows for flexible fees on a per client basis
- Withdrawals
  - some bridges refund the sender if it fails. If this contract ends up with a balance, we need a way to return it to user, so need to support withdrawals preventing lost funds
- Data verification

  - Since we want this to be stateless and secure, we use an operator that signs all transactions created in our backend. This will use engine to sign the transactions.
  - We should be able to switch out this operator. Also, the operator (engine) should be able to programmatically withdraw funds so we can build automated customer support tools

### Build

```shell
$ forge build
```

### Test

```shell
$ forge test
```
