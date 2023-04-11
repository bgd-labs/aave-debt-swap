# BGD labs <> Aave Debt Swap Adapter

This repository contains the [ParaSwapDebtSwapAdapter](./src/contracts/ParaSwapDebtSwapAdapter.sol), which aims to allow users to arbitrage borrow apy and exit illiquid debt positions.
Therefore this contract is able to swap one debt position to another debt position - either partially or complete.

In order to perform this task, `swapDebt`:

1. creates a flashLoan with variable debt mode with the **target debt** on behalf of the user
   - on aave v2 you need to approve the debtSwapAdapter for credit delegation
   - on aave v3 you can also pass a permit
2. swaps the flashed assets to the underlying of the **current debt** via exact out swap
3. repays the **current debt**
4. uses potential excess to repay parts of the newly created **target debt**

The ParaSwapDebtSwapAdapter will always repay on the pool on behalf of the user.
So instead of having approvals per transaction the adapter will approve `type(uint256).max` once to reduce gas consumption.

The `function swapDebt( DebtSwapParams memory debtSwapParams, CreditDelegationInput memory creditDelegationPermit )` expects two parameters.

The first one describes the swap:

```solidity
struct DebtSwapParams {
  address debtAsset; // the asset you want to swap away from
  uint256 debtRepayAmount; // the amount of debt you want to eliminate
  uint256 debtRateMode; // the type of debt (1 for stable, 2 for variable)
  address newDebtAsset; // the asset you want to swap to
  uint256 maxNewDebtAmount; // the max amount of debt your're willing to receive in excahnge for repaying debtRepayAmount
  bytes paraswapData; // encoded exactOut swap
}

```

The second one describes the (optional) creditDelegation permit:

```solidity
struct CreditDelegationInput {
  ICreditDelegationToken debtToken;
  uint256 value;
  uint256 deadline;
  uint8 v;
  bytes32 r;
  bytes32 s;
}

```

For usage examples please check the [tests](./tests/).

## Install

This repo has forge and npm dependencies, so you will need to install foundry then run:

```sh
forge install
```

and also run:

```sh
yarn
```

## Tests

To run the tests just run:

```sh
forge test
```

## References

This code is based on [the existing aave paraswap adapters](https://github.com/aave/aave-v3-periphery/tree/master/contracts/adapters/paraswap) for v3.

The [BaseParaSwapAdapter.sol](./src/contracts/BaseParaSwapAdapter.sol) was slightly adjusted to receive the POOL via constructor instead of fetching it.

This makes the code agnostic for v2 and v3, as the only methods used are unchanged between the two versions.
