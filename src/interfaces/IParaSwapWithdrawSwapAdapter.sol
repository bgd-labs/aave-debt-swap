// SPDX-License-Identifier: MIT
pragma solidity ^0.8.10;

import {BaseParaSwapAdapter} from '../contracts/BaseParaSwapAdapter.sol';

interface IParaSwapWithdrawSwapAdapter {
  struct WithdrawSwapParams {
    address oldAsset;
    uint256 oldAssetAmount;
    address newAsset;
    uint256 minAmountToReceive;
    uint256 allBalanceOffset;
    bytes paraswapData;
  }

  /**
   * @dev Swaps an amount of an asset to another after a withdraw and transfers the new asset to the user.
   * @param withdrawSwapParams struct describing the withdraw swap parameters
   * @param permitParams optional permit for collateral aToken
   */
  function withdrawAndSwap(
    WithdrawSwapParams memory withdrawSwapParams,
    BaseParaSwapAdapter.PermitSignature memory permitParams
  ) external;
}
