# BGD labs <> Aave Debt Swap Adapter

This repository contains the [ParaSwapDebtSwapAdapter](./src/contracts/ParaSwapDebtSwapAdapter.sol), which aims to allow users to arbitrage borrow APY and exit illiquid debt positions.
Therefore, this contract is able to swap one debt position to another debt position - either partially or completely.

You could for example swap your `1000 BUSD` debt to `max(1010 USDC)` debt.
In order to perform this task, `swapDebt`:

1. Creates a flashLoan with variable debt mode with the **target debt**(`1010 USDC`) on behalf of the user
   - On aave v2 you need to approve the debtSwapAdapter for credit delegation
   - On aave v3 you can also pass a credit delegation permit
2. It then swaps the flashed assets to the underlying of the **current debt**(`1000 BUSD`) via exact out swap (meaning it will receive `1000 BUSD`, but might only need `1000.1 USDC` for the swap)
3. Repays the **current debt** (`1000 BUSD`)
4. Uses potential (`9.9 USDC`) to repay parts of the newly created **target debt**

The user has now payed off his `1000 BUSD` debt position, and created a new `1000.1 USDC` debt position.

In situations where a user's real loan-to-value (LTV) is higher than their maximum LTV but lower than their liquidation threshold (LT), extra collateral is needed to "wrap" around the flashloan-and-swap outlined above. The flow would then look like this:

1. Create a standard, repayable flashloan with the specified extra collateral asset and amount
2. Supply the flashed collateral on behalf of the user
3. Create the variable debt flashloan with the **target debt**(`1010 USDC`) on behalf of the user
4. Swap the flashloaned target debt asset to the underlying of the **current debt**(`1000 BUSD`), needing only `1000.1 USDC`
5. Repay the **current debt** (`1000 BUSD`)
6. Repay the flashloaned collateral asset (requires `aToken` approval)
7. Use the remaining new debt asset (`9.9 USDC`) to repay parts of the newly created **target debt**

Notice how steps 3, 4, 5, and 7 are the same four steps from the collateral-less flow.

In order to select adequate extra collateral asset and amount the following rules apply on `Aave V3`:

1. **must not** be frozen
2. has a lt & ltv >0
3. **must not** be isolated
   - except if the user is in isolation, then extra collateral **must** be the same isolated asset
4. supply cap allows supplying the specified amount

On `Aave V2`, due to limitations related to flashloan premium: TBD

Where possible, it is recommended to use the:

1. `fromDebt` asset
2. `toDebt` asset
3. an unrelated high ltv asset

in order to reduce gas costs.

The `function swapDebt(DebtSwapParams memory debtSwapParams, CreditDelegationInput memory creditDelegationPermit, PermitInput memory collateralATokenPermit)` expects three parameters.

The first one describes the swap:

```solidity
struct DebtSwapParams {
  address debtAsset; // the asset you want to swap away from
  uint256 debtRepayAmount; // the amount of debt you want to eliminate
  uint256 debtRateMode; // the type of debt (1 for stable, 2 for variable)
  address newDebtAsset; // the asset you want to swap to
  uint256 maxNewDebtAmount; // the max amount of debt your're willing to receive in excahnge for repaying debtRepayAmount
  address extraCollateralAsset; // The asset to flash and add as collateral if needed
  uint256 extraCollateralAmount; // The amount of `extraCollateralAsset` to flash and supply momentarily
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

The third one describes the (optional) collateral aToken permit:

```solidity
struct PermitInput {
  IERC20WithPermit aToken;
  uint256 value;
  uint256 deadline;
  uint8 v;
  bytes32 r;
  bytes32 s;
}

```

For usage examples please check the [tests](./tests/).

## Security

- This contract is a extra layer on top of [BaseParaswapBuyAdapter](./src/contracts/BaseParaSwapBuyAdapter.sol) which is used in production for [ParaSwapRepayAdapter](https://github.com/aave/aave-v3-periphery/blob/master/contracts/adapters/paraswap/ParaSwapRepayAdapter.sol). It uses the exact same mechanism for exact out swap.

- In contrast to ParaSwapRepayAdapter the ParaSwapDebtSwapAdapter will always repay on the pool on behalf of the user. So instead of having approvals per transaction the adapter will approve `type(uint256).max` once to reduce gas consumption.

- The Aave `POOL` is considered a trustable entity for allowance purposes.

- The contract only interact with `msg.sender` and therefore ensures isolation between users.

- The contract is not upgradable.

- The contract is ownable and will be owned by governance, so the governance will be the only entity able to call `tokenRescue`.

- The approach with credit delegation and borrow-mode flashLoans is very similar to what is done on [V2-V3 Migration helper](https://github.com/bgd-labs/V2-V3-migration-helpers)

- The contract inherits the security and limitations of Aave v2/v3. The contract itself does not validate for frozen/inactive reserves and also does not consider isolation/eMode or borrowCaps. It is the responsibility of the interface integrating this contract to correctly handle all user position compositions and pool configurations.

- The contract implements an upper bound of 30% price impact, which would revert any swap. The slippage has to be properly configured in incorporated into the `DebtSwapParams.maxNewDebt` parameter.

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
