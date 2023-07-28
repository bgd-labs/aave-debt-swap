// SPDX-License-Identifier: MIT
pragma solidity ^0.8.10;

import {DataTypes} from '@aave/core-v3/contracts/protocol/libraries/types/DataTypes.sol';
import {IERC20Detailed} from '@aave/core-v3/contracts/dependencies/openzeppelin/contracts/IERC20Detailed.sol';
import {IERC20} from '@aave/core-v3/contracts/dependencies/openzeppelin/contracts/IERC20.sol';
import {IERC20WithPermit} from 'solidity-utils/contracts/oz-common/interfaces/IERC20WithPermit.sol';
import {IPoolAddressesProvider} from '@aave/core-v3/contracts/interfaces/IPoolAddressesProvider.sol';
import {ReentrancyGuard} from 'aave-v3-periphery/contracts/dependencies/openzeppelin/ReentrancyGuard.sol';
import {BaseParaSwapBuyAdapter} from './BaseParaSwapBuyAdapter.sol';
import {IParaSwapAugustusRegistry} from '../interfaces/IParaSwapAugustusRegistry.sol';
import {IParaSwapAugustus} from '../interfaces/IParaSwapAugustus.sol';
import {IFlashLoanReceiver} from '../interfaces/IFlashLoanReceiver.sol';
import {ICreditDelegationToken} from '../interfaces/ICreditDelegationToken.sol';
import {SafeERC20} from 'solidity-utils/contracts/oz-common/SafeERC20.sol';
import {IParaswapDebtSwapAdapter} from '../interfaces/IParaswapDebtSwapAdapter.sol';

import 'forge-std/console2.sol';

/**
 * @title ParaSwapDebtSwapAdapter
 * @notice ParaSwap Adapter to perform a swap of debt to another debt.
 * @author BGD labs
 **/
abstract contract ParaSwapDebtSwapAdapter is
  BaseParaSwapBuyAdapter,
  ReentrancyGuard,
  IFlashLoanReceiver,
  IParaswapDebtSwapAdapter
{
  using SafeERC20 for IERC20WithPermit;

  // unique identifier to track usage via flashloan events
  uint16 public constant REFERRER = 5936; // uint16(uint256(keccak256(abi.encode('debt-swap-adapter'))) / type(uint16).max)

  constructor(
    IPoolAddressesProvider addressesProvider,
    address pool,
    IParaSwapAugustusRegistry augustusRegistry,
    address owner
  ) BaseParaSwapBuyAdapter(addressesProvider, pool, augustusRegistry) {
    transferOwnership(owner);
    // set initial approval for all reserves
    address[] memory reserves = POOL.getReservesList();
    for (uint256 i = 0; i < reserves.length; i++) {
      IERC20WithPermit(reserves[i]).safeApprove(address(POOL), type(uint256).max);
    }
  }

  function renewAllowance(address reserve) public {
    IERC20WithPermit(reserve).safeApprove(address(POOL), 0);
    IERC20WithPermit(reserve).safeApprove(address(POOL), type(uint256).max);
  }

  /**
   * @dev Swaps one type of debt to another. Therfore this methods performs the following actions in order:
   * 1. Delegate credit in new debt
   * 2. Flashloan in new debt
   * 3. swap new debt to old debt
   * 4. repay old debt
   * @param debtSwapParams the parameters describing the swap
   * @param creditDelegationPermit optional permit for credit delegation
   */
  function swapDebt(
    DebtSwapParams memory debtSwapParams,
    CreditDelegationInput memory creditDelegationPermit
  ) external {
    uint256 excessBefore = IERC20Detailed(debtSwapParams.newDebtAsset).balanceOf(address(this));
    // delegate credit
    if (creditDelegationPermit.deadline != 0) {
      ICreditDelegationToken(creditDelegationPermit.debtToken).delegationWithSig(
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
      (address vToken, address sToken) = _getReserveData(debtSwapParams.debtAsset);
      debtSwapParams.debtRepayAmount = debtSwapParams.debtRateMode == 2
        ? IERC20WithPermit(vToken).balanceOf(msg.sender)
        : IERC20WithPermit(sToken).balanceOf(msg.sender);
    }
    FlashParams memory flashParams = FlashParams(
      debtSwapParams.debtAsset,
      debtSwapParams.debtRepayAmount,
      debtSwapParams.debtRateMode,
      debtSwapParams.newDebtAsset,
      debtSwapParams.maxNewDebtAmount,
      debtSwapParams.paraswapData,
      debtSwapParams.offset,
      msg.sender
    );
    if (debtSwapParams.extraCollateralAsset != address(0)) {
      _flash(
        flashParams,
        debtSwapParams.extraCollateralAsset,
        debtSwapParams.extraCollateralAmount
      );
    } else {
      _flash(flashParams, debtSwapParams.newDebtAsset, debtSwapParams.maxNewDebtAmount);
    }

    // use excess to repay parts of flash debt
    uint256 excessAfter = IERC20Detailed(debtSwapParams.newDebtAsset).balanceOf(address(this));
    uint256 excess = excessAfter - excessBefore;
    if (excess > 0) {
      _conditionalRenewAllowance(debtSwapParams.newDebtAsset, excess);
      POOL.repay(debtSwapParams.newDebtAsset, excess, 2, msg.sender);
    }
  }

  function _flash(FlashParams memory flashParams, address asset, uint256 amount) internal virtual {
    bytes memory params = abi.encode(flashParams);

    address[] memory assets = new address[](1);
    assets[0] = asset;
    uint256[] memory amounts = new uint256[](1);
    amounts[0] = amount;
    uint256[] memory interestRateModes = new uint256[](1);
    // This is only true if there is no need for extra collateral.
    interestRateModes[0] = flashParams.newDebtAsset == asset ? 2 : 0;

    POOL.flashLoan(
      address(this),
      assets,
      amounts,
      interestRateModes,
      flashParams.user,
      params,
      REFERRER
    );
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

    FlashParams memory flashParams = abi.decode(params, (FlashParams));

    if (flashParams.newDebtAsset != assets[0]) {
      console2.log('Flash coll');

      // There is a need for additional collateral, wrap the swap with a supply and withdraw.
      address collateralAsset = assets[0];
      uint256 collateralAmount = amounts[0];

      address aToken = POOL.getReserveData(collateralAsset).aTokenAddress;
      console2.log(
        'Current aToken bal pre supp:',
        IERC20(aToken).balanceOf(flashParams.user) / 1e18
      );

      (, , , , uint256 ltv, uint256 hf) = POOL.getUserAccountData(flashParams.user);
      console2.log('ltv:', ltv);
      console2.log('hf:', hf);
      console2.log('collateralAmount:', collateralAmount / 1e18);

      // Supply
      console2.log(
        'before supply aDai:',
        IERC20WithPermit(0x018008bfb33d285247A21d44E50697654f754e63).balanceOf(flashParams.user)
      );
      POOL.supply(collateralAsset, collateralAmount, flashParams.user, REFERRER);
      console2.log(
        'after supply aDai:',
        IERC20WithPermit(0x018008bfb33d285247A21d44E50697654f754e63).balanceOf(flashParams.user)
      );

      // Execute the nested flashloan
      _flash(flashParams, flashParams.newDebtAsset, flashParams.maxNewDebtAmount);
      console2.log('passed normal flash after coll');
      (, , , , ltv, hf) = POOL.getUserAccountData(flashParams.user);
      console2.log('ltv:', ltv);
      console2.log('hf:', hf);
      console2.log('collateralAmount:', collateralAmount / 1e18);

      // Fetch and transfer back in the aToken to allow the pool to pull it.
      aToken = POOL.getReserveData(collateralAsset).aTokenAddress;
      console2.log('Current aToken bal:', IERC20(aToken).balanceOf(flashParams.user) / 1e18);
      IERC20WithPermit(aToken).safeTransferFrom(flashParams.user, address(this), collateralAmount); // Could be rounding error but it's insignificant
      POOL.withdraw(collateralAsset, collateralAmount, address(this));
      _conditionalRenewAllowance(collateralAsset, collateralAmount);

      // Return out of this scope.
      return true;
    }

    console2.log('Flash normal');
    // There is no need for additional collateral, execute the swap.
    _swapAndRepay(flashParams, IERC20Detailed(assets[0]), amounts[0]);
    console2.log('Passed normal swap&repay');
    (uint256 collateralBase, , , , , ) = POOL.getUserAccountData(flashParams.user);
    console2.log('Collateral after all:', collateralBase);
    return true;
  }

  /**
   * @dev Swaps the flashed token to the debt token & repays the debt.
   * @param swapParams Decoded swap parameters
   * @param newDebtAsset Address of token to be swapped
   * @param newDebtAmount Amount of the reserve to be swapped(flash loan amount)
   */
  function _swapAndRepay(
    FlashParams memory swapParams,
    IERC20Detailed newDebtAsset,
    uint256 newDebtAmount
  ) internal returns (uint256) {
    uint256 amountSold = _buyOnParaSwap(
      swapParams.offset,
      swapParams.paraswapData,
      newDebtAsset,
      IERC20Detailed(swapParams.debtAsset),
      newDebtAmount,
      swapParams.debtRepayAmount
    );

    _conditionalRenewAllowance(swapParams.debtAsset, swapParams.debtRepayAmount);

    POOL.repay(
      address(swapParams.debtAsset),
      swapParams.debtRepayAmount,
      swapParams.debtRateMode,
      swapParams.user
    );
    return amountSold;
  }

  function _conditionalRenewAllowance(address asset, uint256 minAmount) internal {
    uint256 allowance = IERC20(asset).allowance(address(this), address(POOL));
    if (allowance < minAmount) {
      renewAllowance(asset);
    }
  }
}
