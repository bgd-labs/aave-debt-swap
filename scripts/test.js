const { constructSimpleSDK, SwapSide } = require("@paraswap/sdk");
const axios = require("axios");
const { defaultAbiCoder } = require("ethers/lib/utils");

const args = process.argv.slice(2);

const CHAIN_ID = args[0];
const FROM = args[1];
const TO = args[2];
const AMOUNT = args[3];
const USER_ADDRESS = args[4];
const METHOD = SwapSide.SELL;

const paraSwapMin = constructSimpleSDK({ chainId: CHAIN_ID, axios });

async function main(from, to, method, amount, user) {
  const priceRoute = await paraSwapMin.swap.getRate({
    srcToken: from,
    destToken: to,
    amount: amount,
    side: method,
  });
  // console.log(priceRoute);

  const txParams = await paraSwapMin.swap.buildTx(
    {
      srcToken: priceRoute.srcToken,
      destToken: priceRoute.destToken,
      srcAmount: priceRoute.srcAmount,
      destAmount: priceRoute.destAmount,
      priceRoute,
      userAddress: user,
      partner: "aave",
    },
    { ignoreChecks: true }
  );
  const encodedData = defaultAbiCoder.encode(
    ["address", "bytes", "uint256"],
    [txParams.to, txParams.data, priceRoute.destAmount]
  );

  process.stdout.write(encodedData);
}
main(FROM, TO, METHOD, AMOUNT, USER_ADDRESS);
