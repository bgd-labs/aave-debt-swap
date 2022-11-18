// SPDX-License-Identifier: agpl-3.0
pragma solidity ^0.8.10;

import {DataTypes} from '@aave/core-v3/contracts/protocol/libraries/types/DataTypes.sol';
import {IERC20Detailed} from '@aave/core-v3/contracts/dependencies/openzeppelin/contracts/IERC20Detailed.sol';
import {IERC20} from '@aave/core-v3/contracts/dependencies/openzeppelin/contracts/IERC20.sol';
import {IERC20WithPermit} from '@aave/core-v3/contracts/interfaces/IERC20WithPermit.sol';
import {IPoolAddressesProvider} from '@aave/core-v3/contracts/interfaces/IPoolAddressesProvider.sol';
import {SafeMath} from '@aave/core-v3/contracts/dependencies/openzeppelin/contracts/SafeMath.sol';
import {ReentrancyGuard} from 'aave-v3-periphery/contracts/dependencies/openzeppelin/ReentrancyGuard.sol';
import {BaseParaSwapBuyAdapter} from './BaseParaSwapBuyAdapter.sol';
import {IParaSwapAugustusRegistry} from '../interfaces/IParaSwapAugustusRegistry.sol';
import {IParaSwapAugustus} from '../interfaces/IParaSwapAugustus.sol';
import {IFlashLoanReceiver} from '../interfaces/IFlashLoanReceiver.sol';

/**
 * @title ParaSwapDebtSwapAdapter
 * @notice ParaSwap Adapter to perform a repay of a debt with collateral.
 * @author BGD
 **/
contract ParaSwapDebtSwapAdapter is
  BaseParaSwapBuyAdapter,
  ReentrancyGuard,
  IFlashLoanReceiver
{
  using SafeMath for uint256;

  constructor(
    IPoolAddressesProvider addressesProvider,
    IParaSwapAugustusRegistry augustusRegistry,
    address owner
  ) BaseParaSwapBuyAdapter(addressesProvider, augustusRegistry) {
    transferOwnership(owner);
  }

  /**
   * @notice Executes an operation after receiving the flash-borrowed assets
   * @dev Ensure that the contract can return the debt + premium, e.g., has
   *      enough funds to repay and has approved the Pool to pull the total amount
   * @param assets The addresses of the flash-borrowed assets
   * @param amounts The amounts of the flash-borrowed assets
   * @param premiums The fee of each flash-borrowed asset
   * @param initiator The address of the flashloan initiator
   * @param params The byte-encoded params passed when initiating the flashloan
   * @return True if the execution of the operation succeeds, false otherwise
   */
  function executeOperation(
    address[] calldata assets,
    uint256[] calldata amounts,
    uint256[] calldata premiums,
    address initiator,
    bytes calldata params
  ) external returns (bool) {
    require(msg.sender == address(POOL), 'CALLER_MUST_BE_POOL');

    uint256 newDebtAmount = amounts[0];
    address initiatorLocal = initiator;

    IERC20Detailed newDebtAsset = IERC20Detailed(assets[0]);

    _swapAndRepay(
      params,
      premiums[0],
      initiatorLocal,
      newDebtAsset,
      newDebtAmount
    );

    return true;
  }

  /**
   * @dev Perform the repay of the debt, pulls the initiator collateral and swaps to repay the flash loan
   * @param premium Fee of the flash loan
   * @param initiator Address of the user
   * @param collateralAsset Address of token to be swapped
   * @param collateralAmount Amount of the reserve to be swapped(flash loan amount)
   */

  function _swapAndRepay(
    bytes calldata params,
    uint256 premium,
    address initiator,
    IERC20Detailed collateralAsset,
    uint256 collateralAmount
  ) private {
    (
      IERC20Detailed debtAsset,
      uint256 debtRepayAmount,
      uint256 buyAllBalanceOffset,
      uint256 rateMode,
      bytes memory paraswapData,
      PermitSignature memory permitSignature
    ) = abi.decode(
        params,
        (IERC20Detailed, uint256, uint256, uint256, bytes, PermitSignature)
      );

    debtRepayAmount = getDebtRepayAmount(
      debtAsset,
      rateMode,
      buyAllBalanceOffset,
      debtRepayAmount,
      initiator
    );

    uint256 amountSold = _buyOnParaSwap(
      buyAllBalanceOffset,
      paraswapData,
      collateralAsset,
      debtAsset,
      collateralAmount,
      debtRepayAmount
    );

    // Repay debt. Approves for 0 first to comply with tokens that implement the anti frontrunning approval fix.
    IERC20(debtAsset).approve(address(POOL), 0);
    IERC20(debtAsset).approve(address(POOL), debtRepayAmount);
    POOL.repay(address(debtAsset), debtRepayAmount, rateMode, initiator);

    // Repay flashloan with dust. Approves for 0 first to comply with tokens that implement the anti frontrunning approval fix.
    IERC20(collateralAsset).approve(address(POOL), 0);
    IERC20(collateralAsset).approve(
      address(POOL),
      collateralAmount.add(premium)
    );
  }

  function getDebtRepayAmount(
    IERC20Detailed debtAsset,
    uint256 rateMode,
    uint256 buyAllBalanceOffset,
    uint256 debtRepayAmount,
    address initiator
  ) private view returns (uint256) {
    DataTypes.ReserveData memory debtReserveData = _getReserveData(
      address(debtAsset)
    );

    address debtToken = DataTypes.InterestRateMode(rateMode) ==
      DataTypes.InterestRateMode.STABLE
      ? debtReserveData.stableDebtTokenAddress
      : debtReserveData.variableDebtTokenAddress;

    uint256 currentDebt = IERC20(debtToken).balanceOf(initiator);

    if (buyAllBalanceOffset != 0) {
      require(currentDebt <= debtRepayAmount, 'INSUFFICIENT_AMOUNT_TO_REPAY');
      debtRepayAmount = currentDebt;
    } else {
      require(debtRepayAmount <= currentDebt, 'INVALID_DEBT_REPAY_AMOUNT');
    }

    return debtRepayAmount;
  }
}
