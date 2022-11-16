const { constructSimpleSDK, SwapSide } = require("@paraswap/sdk");
const axios = require("axios");
const { BigNumber } = require("ethers");
const { defaultAbiCoder } = require("ethers/lib/utils");

const args = process.argv.slice(2);

const CHAIN_ID = args[0];
const FROM = args[1];
const TO = args[2];
const AMOUNT = args[3];
const USER_ADDRESS = args[4];
const METHOD = args[5];

const paraSwapMin = constructSimpleSDK({ chainId: CHAIN_ID, axios });

const maxSlippage = 3;

async function main(from, to, method, amount, user) {
  const priceRoute = await paraSwapMin.swap.getRate({
    srcToken: from,
    srcDecimals: 18,
    destToken: to,
    destDecimals: 18,
    amount: amount,
    side: method,
  });

  const txParams = await paraSwapMin.swap.buildTx(
    {
      srcToken: priceRoute.srcToken,
      destToken: priceRoute.destToken,
      srcAmount:
        METHOD === SwapSide.SELL
          ? priceRoute.srcAmount
          : BigNumber.from(priceRoute.srcAmount)
              .mul(100 + maxSlippage)
              .div(100)
              .toString(),
      destAmount:
        METHOD === SwapSide.SELL
          ? BigNumber.from(priceRoute.srcAmount)
              .mul(100 - maxSlippage)
              .div(100)
              .toString()
          : priceRoute.destAmount,
      priceRoute,
      userAddress: user,
      partner: "aave",
    },
    { ignoreChecks: true }
  );
  const encodedData = defaultAbiCoder.encode(
    ["address", "bytes", "uint256", "uint256"],
    [txParams.to, txParams.data, priceRoute.srcAmount, priceRoute.destAmount]
  );

  process.stdout.write(encodedData);
}
main(FROM, TO, METHOD, AMOUNT, USER_ADDRESS);
