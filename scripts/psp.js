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
const MAX_SLIPPAGE = Number(args[6]);
const MAX = args[7] === "true";
const FROM_DECIMALS = Number(args[8]);
const TO_DECIMALS = Number(args[9]);

const paraSwapMin = constructSimpleSDK({ chainId: CHAIN_ID, axios });

function augustusFromAmountOffsetFromCalldata(calldata) {
  switch (calldata.slice(0, 10)) {
    case "0xda8567c8": // Augustus V3 multiSwap
      return 100; // 4 + 3 * 32
    case "0x58b9d179": // Augustus V4 swapOnUniswap
      return 4; // 4 + 0 * 32
    case "0x0863b7ac": // Augustus V4 swapOnUniswapFork
      return 68; // 4 + 2 * 32
    case "0x8f00eccb": // Augustus V4 multiSwap
      return 68; // 4 + 2 * 32
    case "0xec1d21dd": // Augustus V4 megaSwap
      return 68; // 4 + 2 * 32
    case "0x54840d1a": // Augustus V5 swapOnUniswap
      return 4; // 4 + 0 * 32
    case "0xf5661034": // Augustus V5 swapOnUniswapFork
      return 68; // 4 + 2 * 32
    case "0x0b86a4c1": // Augustus V5 swapOnUniswapV2Fork
      return 36; // 4 + 1 * 32
    case "0x64466805": // Augustus V5 swapOnZeroXv4
      return 68; // 4 + 2 * 32
    case "0xa94e78ef": // Augustus V5 multiSwap
      return 68; // 4 + 2 * 32
    case "0x46c67b6d": // Augustus V5 megaSwap
      return 68; // 4 + 2 * 32
    default:
      throw new Error("Unrecognized function selector for Augustus");
  }
}

const augustusToAmountOffsetFromCalldata = (calldata) => {
  switch (calldata.slice(0, 10)) {
    case "0x935fb84b": // Augustus V5 buyOnUniswap
      return 36; // 4 + 1 * 32
    case "0xc03786b0": // Augustus V5 buyOnUniswapFork
      return 100; // 4 + 3 * 32
    case "0xb2f1e6db": // Augustus V5 buyOnUniswapV2Fork
      return 68; // 4 + 2 * 32
    case "0xb66bcbac": // Augustus V5 buy (old)
    case "0x35326910": // Augustus V5 buy
      return 164; // 4 + 5 * 32
    default:
      throw new Error("Unrecognized function selector for Augustus");
  }
};

async function main(from, to, method, amount, user) {
  const priceRoute = await paraSwapMin.swap.getRate({
    srcToken: from,
    srcDecimals: FROM_DECIMALS,
    destToken: to,
    destDecimals: TO_DECIMALS,
    amount: amount,
    side: method,
  });

  const srcAmount =
    METHOD === SwapSide.SELL
      ? priceRoute.srcAmount
      : BigNumber.from(priceRoute.srcAmount)
          .mul(100 + MAX_SLIPPAGE)
          .div(100)
          .toString();
  const destAmount =
    METHOD === SwapSide.SELL
      ? BigNumber.from(priceRoute.destAmount)
          .mul(100 - MAX_SLIPPAGE)
          .div(100)
          .toString()
      : priceRoute.destAmount;

  const txParams = await paraSwapMin.swap.buildTx(
    {
      srcToken: from,
      srcDecimals: FROM_DECIMALS,
      destToken: to,
      destDecimals: TO_DECIMALS,
      srcAmount,
      destAmount,
      priceRoute,
      userAddress: user,
      partner: "aave",
    },
    { ignoreChecks: true }
  );
  const offset = MAX
    ? method === "SELL"
      ? augustusFromAmountOffsetFromCalldata(txParams.data)
      : augustusToAmountOffsetFromCalldata(txParams.data)
    : "0x00000000";

  const encodedData = defaultAbiCoder.encode(
    ["address", "bytes", "uint256", "uint256", "bytes4"],
    [txParams.to, txParams.data, srcAmount, destAmount, offset]
  );

  process.stdout.write(encodedData);
}
main(FROM, TO, METHOD, AMOUNT, USER_ADDRESS);
