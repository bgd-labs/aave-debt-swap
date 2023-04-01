// SPDX-License-Identifier: agpl-3.0
pragma solidity ^0.8.10;

import 'forge-std/Test.sol';
import {DataTypes} from '@aave/core-v3/contracts/protocol/libraries/types/DataTypes.sol';
import {IERC20Detailed} from '@aave/core-v3/contracts/dependencies/openzeppelin/contracts/IERC20Detailed.sol';
import {IERC20} from '@aave/core-v3/contracts/dependencies/openzeppelin/contracts/IERC20.sol';
import {IERC20WithPermit} from 'solidity-utils/contracts/oz-common/interfaces/IERC20WithPermit.sol';
import {IPoolAddressesProvider} from '@aave/core-v3/contracts/interfaces/IPoolAddressesProvider.sol';
import {SafeMath} from '@aave/core-v3/contracts/dependencies/openzeppelin/contracts/SafeMath.sol';
import {ReentrancyGuard} from 'aave-v3-periphery/contracts/dependencies/openzeppelin/ReentrancyGuard.sol';
import {BaseParaSwapBuyAdapter} from './BaseParaSwapBuyAdapter.sol';
import {IParaSwapAugustusRegistry} from '../interfaces/IParaSwapAugustusRegistry.sol';
import {IParaSwapAugustus} from '../interfaces/IParaSwapAugustus.sol';
import {IFlashLoanReceiver} from '../interfaces/IFlashLoanReceiver.sol';
import {ICreditDelegationToken} from '../interfaces/ICreditDelegationToken.sol';
import {SafeERC20} from 'solidity-utils/contracts/oz-common/SafeERC20.sol';

/**
 * @title ParaSwapDebtSwapAdapter
 * @notice ParaSwap Adapter to perform a swap of debt to another debt.
 * @author BGD
 **/
contract ParaSwapDebtSwapAdapter is BaseParaSwapBuyAdapter, ReentrancyGuard, IFlashLoanReceiver {
  using SafeERC20 for IERC20WithPermit;
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
        vTokens[reserves[i]] = IERC20WithPermit(reserveData.variableDebtTokenAddress);
        sTokens[reserves[i]] = IERC20WithPermit(reserveData.stableDebtTokenAddress);
        IERC20WithPermit(reserves[i]).safeApprove(address(POOL), type(uint256).max);
      }
    }
  }

  function renewAllowance(address reserve) public {
    IERC20WithPermit(reserve).safeApprove(address(POOL), 0);
    IERC20WithPermit(reserve).safeApprove(address(POOL), type(uint256).max);
  }

  struct FlashParams {
    address debtAsset;
    uint256 debtRepayAmount;
    uint256 debtRateMode;
    bytes paraswapData;
    address user;
  }

  struct DebtSwapParams {
    address debtAsset;
    uint256 debtRepayAmount;
    uint256 debtRateMode;
    address newDebtAsset;
    uint256 maxNewDebtAmount;
    uint256 newDebtRateMode;
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

  /**
   * 1. Delegate credit in new debt
   * 2. Flashloan in new debt
   * 3. swap new debt to old debt
   * 4. repay old debt
   * @param debtSwapParams y
   */
  function swapDebt(
    DebtSwapParams memory debtSwapParams,
    CreditDelegationInput memory creditDelegationPermit
  ) public {
    uint256 excessBefore = IERC20Detailed(debtSwapParams.newDebtAsset).balanceOf(address(this));
    // delegate credit
    if (creditDelegationPermit.deadline != 0) {
      ICreditDelegationToken(debtSwapParams.newDebtAsset).delegationWithSig(
        msg.sender,
        address(this),
        creditDelegationPermit.value,
        creditDelegationPermit.deadline,
        creditDelegationPermit.v,
        creditDelegationPermit.r,
        creditDelegationPermit.s
      );
    }
    // flash & repay
    if (debtSwapParams.debtRepayAmount == type(uint256).max) {
      debtSwapParams.debtRepayAmount = debtSwapParams.debtRateMode == 2
        ? vTokens[address(debtSwapParams.debtAsset)].balanceOf(msg.sender)
        : sTokens[address(debtSwapParams.debtAsset)].balanceOf(msg.sender);
    }
    FlashParams memory flashParams = FlashParams(
      debtSwapParams.debtAsset,
      debtSwapParams.debtRepayAmount,
      debtSwapParams.debtRateMode,
      debtSwapParams.paraswapData,
      msg.sender
    );
    bytes memory params = abi.encode(flashParams);
    address[] memory assets = new address[](1);
    assets[0] = debtSwapParams.newDebtAsset;
    uint256[] memory amounts = new uint256[](1);
    amounts[0] = debtSwapParams.maxNewDebtAmount;
    uint256[] memory interestRateModes = new uint256[](1);
    interestRateModes[0] = debtSwapParams.newDebtRateMode;
    POOL.flashLoan(address(this), assets, amounts, interestRateModes, msg.sender, params, REFERRER);

    // use excess to repay parts of flash debt
    uint256 excessAfter = IERC20Detailed(debtSwapParams.newDebtAsset).balanceOf(address(this));
    uint256 excess = excessAfter - excessBefore;
    if (excess > 0) {
      uint256 allowance = IERC20(debtSwapParams.newDebtAsset).allowance(
        address(this),
        address(POOL)
      );
      if (allowance < excess) {
        renewAllowance(debtSwapParams.newDebtAsset);
      }
      POOL.repay(debtSwapParams.newDebtAsset, excess, debtSwapParams.newDebtRateMode, msg.sender);
    }
  }

  /**
   * @notice Executes an operation after receiving the flash-borrowed assets
   * @dev Ensure that the contract can return the debt + premium, e.g., has
   *      enough funds to repay and has approved the Pool to pull the total amount
   * @param assets The addresses of the flash-borrowed assets
   * @param amounts The amounts of the flash-borrowed assets
   * @param initiator The address of the flashloan initiator
   * @param params The byte-encoded params passed when initiating the flashloan
   * @return True if the execution of the operation succeeds, false otherwise
   */
  function executeOperation(
    address[] calldata assets,
    uint256[] calldata amounts,
    uint256[] calldata,
    address initiator,
    bytes calldata params
  ) external returns (bool) {
    require(msg.sender == address(POOL), 'CALLER_MUST_BE_POOL');
    require(initiator == address(this), 'INITIATOR_MUST_BE_THIS');

    _swapAndRepay(params, initiator, IERC20Detailed(assets[0]), amounts[0]);

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
    FlashParams memory swapParams = abi.decode(params, (FlashParams));

    uint256 amountSold = _buyOnParaSwap(
      0,
      swapParams.paraswapData,
      newDebtAsset,
      IERC20Detailed(swapParams.debtAsset),
      newDebtAmount,
      swapParams.debtRepayAmount
    );

    uint256 allowance = IERC20(swapParams.debtAsset).allowance(address(this), address(POOL));

    if (allowance < swapParams.debtRepayAmount) {
      renewAllowance(address(swapParams.debtAsset));
    }
    POOL.repay(
      address(swapParams.debtAsset),
      swapParams.debtRepayAmount,
      swapParams.debtRateMode,
      swapParams.user
    );
  }
}
