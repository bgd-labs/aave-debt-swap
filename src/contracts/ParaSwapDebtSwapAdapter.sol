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
 * @notice ParaSwap Adapter to perform a swap of debt to another debt.
 * @author BGD
 **/
contract ParaSwapDebtSwapAdapter is
  BaseParaSwapBuyAdapter,
  ReentrancyGuard,
  IFlashLoanReceiver
{
  using SafeMath for uint256;

  uint16 constant REFERRER = 100;

  mapping(address => IERC20WithPermit) public aTokens;
  mapping(address => IERC20WithPermit) public vTokens;
  mapping(address => IERC20WithPermit) public sTokens;

  constructor(
    IPoolAddressesProvider addressesProvider,
    IParaSwapAugustusRegistry augustusRegistry,
    address owner
  ) BaseParaSwapBuyAdapter(addressesProvider, augustusRegistry) {
    transferOwnership(owner);
    cacheReserves();
  }

  /**
   * @dev caches all reserves
   */
  function cacheReserves() public {
    address[] memory reserves = POOL.getReservesList();
    for (uint256 i = 0; i < reserves.length; i++) {
      if (address(aTokens[reserves[i]]) == address(0)) {
        cacheReserve(reserves[i]);
      }
    }
  }

  /**
   * @dev Adds a reserve to the cache & renewes the approval
   */
  function cacheReserve(address reserve) public {
    DataTypes.ReserveData memory reserveData = _getReserveData(reserve);
    aTokens[reserve] = IERC20WithPermit(reserveData.aTokenAddress);
    vTokens[reserve] = IERC20WithPermit(reserveData.variableDebtTokenAddress);
    sTokens[reserve] = IERC20WithPermit(reserveData.stableDebtTokenAddress);

    IERC20WithPermit(reserve).approve(address(POOL), 0);
    IERC20WithPermit(reserve).approve(address(POOL), type(uint256).max);
  }

  /**
   * @notice Swaps one debt(variable or stable) to another debt(variable)
   * @dev Performs the following actions:
   * 0. delegate credit in new debt asset to the debtSwap
   * 1. flash current debt asset
   * 2. repay specified amount of debt
   * 3. borrow new debt + potential swap slippage
   * 4. swap borrowed asset exact out to current debt
   * 5. repay flashloan
   * 6. repay new debt with leftover
   * @param debtAsset The asset of current debt
   * @param rateMode The rateMode of the debtAsset
   * @param debtAmount The amount of debt to be swapped
   * @param newDebtAsset The asset in which the new variable debt is created
   */
  function swapDebt(
    address debtAsset,
    uint256 debtAmount,
    address newDebtAsset,
    uint256 buyAllBalanceOffset,
    uint256 rateMode,
    bytes memory paraswapData
  ) public {
    // TODO: credit delegation
    POOL.flashLoanSimple(
      address(this),
      debtAsset,
      debtAmount + 1 ether, // TODO: should be exact premium
      abi.encode(
        newDebtAsset,
        buyAllBalanceOffset,
        rateMode,
        paraswapData,
        msg.sender
      ),
      REFERRER
    );
  }

  /**
   * @notice Executes an operation after receiving the flash-borrowed assets
   * @dev Ensure that the contract can return the debt + premium, e.g., has
   *      enough funds to repay and has approved the Pool to pull the total amount
   * @param asset The addresses of the flash-borrowed assets
   * @param amount The amounts of the flash-borrowed assets
   * @param premium The fee of each flash-borrowed asset
   * @param initiator The address of the flashloan initiator
   * @param params The byte-encoded params passed when initiating the flashloan
   * @return True if the execution of the operation succeeds, false otherwise
   */
  function executeOperation(
    address asset,
    uint256 amount,
    uint256 premium,
    address initiator,
    bytes calldata params
  ) external returns (bool) {
    require(msg.sender == address(POOL), 'CALLER_MUST_BE_POOL');
    require(initiator == address(this), 'INITIATIOR_MUST_BE_DEBTSWAP');

    (
      IERC20Detailed newDebtAsset,
      uint256 maxNewDebtAmount,
      uint256 buyAllBalanceOffset,
      uint256 rateMode,
      bytes memory paraswapData,
      address user
    ) = abi.decode(
        params,
        (IERC20Detailed, uint256, uint256, uint256, bytes, address)
      );

    // 1. repay debt with flashed asset
    POOL.repay(address(asset), amount, rateMode, user);

    // 2. borrow on behalf of the user
    POOL.borrow(
      address(newDebtAsset),
      maxNewDebtAmount,
      uint256(DataTypes.InterestRateMode.VARIABLE),
      REFERRER,
      user
    );

    // 3. swap newDebtAsset to flashedAsset with exact out
    uint256 amountSold = _buyOnParaSwap(
      0,
      paraswapData,
      newDebtAsset,
      IERC20Detailed(asset),
      maxNewDebtAmount,
      amount
    );

    // 4. repay newDebtAsset with leftovers
    POOL.repay(
      address(newDebtAsset),
      newDebtAsset.balanceOf(address(this)),
      uint256(DataTypes.InterestRateMode.VARIABLE),
      user
    );

    return true;
  }
}
