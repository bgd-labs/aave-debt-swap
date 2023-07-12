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

// OpenZeppelin Contracts (last updated v4.9.0) (interfaces/IERC3156FlashBorrower.sol)
/**
 * @dev Interface of the ERC3156 FlashBorrower, as defined in
 * https://eips.ethereum.org/EIPS/eip-3156[ERC-3156].
 */
interface IERC3156FlashBorrower {
  /**
   * @dev Receive a flash loan.
   * @param initiator The initiator of the loan.
   * @param token The loan currency.
   * @param amount The amount of tokens lent.
   * @param fee The additional amount of tokens to repay.
   * @param data Arbitrary data structure, intended to contain user-defined parameters.
   * @return The keccak256 hash of "ERC3156FlashBorrower.onFlashLoan"
   */
  function onFlashLoan(
    address initiator,
    address token,
    uint256 amount,
    uint256 fee,
    bytes calldata data
  ) external returns (bytes32);
}

// https://github.com/aave/gho-core/blob/main/src/contracts/facilitators/flashMinter/GhoFlashMinter.sol does not contain `flashLoan` method
interface FlashMinterMock {
  function flashLoan(
    IERC3156FlashBorrower receiver,
    address token,
    uint256 amount,
    bytes calldata data
  ) external returns (bool);
}

/**
 * @title ParaSwapDebtSwapAdapter
 * @notice ParaSwap Adapter to perform a swap of debt to another debt.
 * @author BGD labs
 **/
abstract contract ParaSwapDebtSwapAdapter is
  BaseParaSwapBuyAdapter,
  ReentrancyGuard,
  IFlashLoanReceiver,
  IParaswapDebtSwapAdapter,
  IERC3156FlashBorrower
{
  using SafeERC20 for IERC20WithPermit;

  // unique identifier to track usage via flashloan events
  uint16 public constant REFERRER = 5936; // uint16(uint256(keccak256(abi.encode('debt-swap-adapter'))) / type(uint16).max)

  // GHO special case
  address public constant GHO = 0x40D16FC0246aD3160Ccc09B8D0D3A2cD28aE6C2f;
  FlashMinterMock public constant GHO_FLASH_MINTER =
    FlashMinterMock(0xb639D208Bcf0589D54FaC24E655C79EC529762B8);

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
      debtSwapParams.paraswapData,
      debtSwapParams.offset,
      msg.sender
    );
    if (debtSwapParams.newDebtAsset == GHO) {
      GHO_FLASH_MINTER.flashLoan(
        IERC3156FlashBorrower(address(this)),
        GHO,
        debtSwapParams.maxNewDebtAmount,
        abi.encode(flashParams)
      );
    } else {
      bytes memory params = abi.encode(flashParams);
      address[] memory assets = new address[](1);
      assets[0] = debtSwapParams.newDebtAsset;
      uint256[] memory amounts = new uint256[](1);
      amounts[0] = debtSwapParams.maxNewDebtAmount;
      uint256[] memory interestRateModes = new uint256[](1);
      interestRateModes[0] = 2;
      POOL.flashLoan(
        address(this),
        assets,
        amounts,
        interestRateModes,
        msg.sender,
        params,
        REFERRER
      );
    }

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
      POOL.repay(debtSwapParams.newDebtAsset, excess, 2, msg.sender);
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

    FlashParams memory swapParams = abi.decode(params, (FlashParams));
    _swapAndRepay(swapParams, IERC20Detailed(assets[0]), amounts[0]);

    return true;
  }

  /// @dev ERC-3156 Flash loan callback (in this case flash mint)
  function onFlashLoan(
    address initiator,
    address token,
    uint256 amount,
    uint256 fee,
    bytes calldata data
  ) external override returns (bytes32) {
    require(initiator == address(this), 'INITIATOR_MUST_BE_THIS');
    require(token == GHO, 'MUST_BE_GHO');
    FlashParams memory swapParams = abi.decode(data, (FlashParams));
    uint256 amountSold = _swapAndRepay(swapParams, IERC20Detailed(token), amount);
    POOL.borrow(GHO, (amountSold + fee), 1, REFERRER, swapParams.user);

    return keccak256('ERC3156FlashBorrower.onFlashLoan');
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
  ) private returns (uint256) {
    uint256 amountSold = _buyOnParaSwap(
      swapParams.offset,
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
    return amountSold;
  }
}
