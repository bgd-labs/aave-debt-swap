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
import {ICreditDelegationToken} from '../interfaces/ICreditDelegationToken.sol';

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
    DataTypes.ReserveData memory reserveData;
    address[] memory reserves = POOL.getReservesList();
    for (uint256 i = 0; i < reserves.length; i++) {
      if (address(aTokens[reserves[i]]) == address(0)) {
        reserveData = POOL.getReserveData(reserves[i]);
        aTokens[reserves[i]] = IERC20WithPermit(reserveData.aTokenAddress);
        vTokens[reserves[i]] = IERC20WithPermit(
          reserveData.variableDebtTokenAddress
        );
        sTokens[reserves[i]] = IERC20WithPermit(
          reserveData.stableDebtTokenAddress
        );
        IERC20WithPermit(reserves[i]).approve(address(POOL), type(uint256).max);
      }
    }
  }

  function renewAllowance(address reserve) public {
    IERC20WithPermit(reserve).approve(address(POOL), 0);
    IERC20WithPermit(reserve).approve(address(POOL), type(uint256).max);
  }

  struct FlashloanParams {
    address asset;
    uint256 amount;
    uint256 interestRateMode;
  }

  struct SwapParams {
    IERC20Detailed debtAsset;
    uint256 debtRepayAmount;
    uint256 rateMode;
    bytes paraswapData;
  }

  struct CreditDelegationInput {
    ICreditDelegationToken debtToken;
    uint256 value;
    uint256 deadline;
    uint8 v;
    bytes32 r;
    bytes32 s;
  }

  function swapDebt(
    FlashloanParams memory flashloanParams,
    SwapParams memory swapParams,
    CreditDelegationInput memory creditDelegationPermit
  ) public {
    ICreditDelegationToken(flashloanParams.asset).delegationWithSig(
      msg.sender,
      address(this),
      creditDelegationPermit.value,
      creditDelegationPermit.deadline,
      creditDelegationPermit.v,
      creditDelegationPermit.r,
      creditDelegationPermit.s
    );
    if (swapParams.debtRepayAmount == type(uint256).max) {
      swapParams.debtRepayAmount = swapParams.rateMode == 2
        ? vTokens[address(swapParams.debtAsset)].balanceOf(msg.sender)
        : sTokens[address(swapParams.debtAsset)].balanceOf(msg.sender);
    }
    bytes memory params = abi.encode(swapParams);

    address[] memory assets = new address[](1);
    assets[0] = flashloanParams.asset;
    uint256[] memory amounts = new uint256[](1);
    amounts[0] = flashloanParams.amount;
    uint256[] memory interestRateModes = new uint256[](1);
    interestRateModes[0] = flashloanParams.interestRateMode;
    POOL.flashLoan(
      address(this),
      assets,
      amounts,
      interestRateModes,
      msg.sender,
      params,
      REFERRER
    );
    uint256 excess = IERC20Detailed(flashloanParams.asset).balanceOf(
      address(this)
    );
    if (excess > 0) {
      POOL.repay(
        address(flashloanParams.asset),
        excess,
        flashloanParams.interestRateMode,
        msg.sender
      );
    }
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
    require(initiator == address(this), 'INITIATOR_MUST_BE_THIS');

    uint256 newDebtAmount = amounts[0];
    address initiatorLocal = initiator;

    IERC20Detailed newDebtAsset = IERC20Detailed(assets[0]);

    _swapAndRepay(params, initiatorLocal, newDebtAsset, newDebtAmount);

    return true;
  }

  /**
   * @dev Swaps the flashed token to the debt token & repays the debt.
   * @param initiator Address of the user
   * @param newDebtAsset Address of token to be swapped
   * @param newDebtAmount Amount of the reserve to be swapped(flash loan amount)
   */
  function _swapAndRepay(
    bytes calldata params,
    address initiator,
    IERC20Detailed newDebtAsset,
    uint256 newDebtAmount
  ) private {
    (
      IERC20Detailed debtAsset,
      uint256 debtRepayAmount,
      uint256 buyAllBalanceOffset,
      uint256 rateMode,
      bytes memory paraswapData
    ) = abi.decode(params, (IERC20Detailed, uint256, uint256, uint256, bytes));

    uint256 amountSold = _buyOnParaSwap(
      buyAllBalanceOffset,
      paraswapData,
      newDebtAsset,
      debtAsset,
      newDebtAmount,
      debtRepayAmount
    );

    uint256 allowance = IERC20(debtAsset).allowance(
      address(this),
      address(POOL)
    );

    if (allowance < debtRepayAmount) {
      renewAllowance(address(debtAsset));
    }
    POOL.repay(address(debtAsset), debtRepayAmount, rateMode, initiator);
  }
}
