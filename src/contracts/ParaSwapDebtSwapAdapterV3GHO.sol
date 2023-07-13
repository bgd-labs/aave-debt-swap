// SPDX-License-Identifier: MIT
pragma solidity ^0.8.10;

import 'forge-std/Test.sol';
import {ParaSwapDebtSwapAdapterV3} from './ParaSwapDebtSwapAdapterV3.sol';
import {IPoolAddressesProvider} from '@aave/core-v3/contracts/interfaces/IPoolAddressesProvider.sol';
import {IParaSwapAugustusRegistry} from '../interfaces/IParaSwapAugustusRegistry.sol';
import {IERC20Detailed} from '@aave/core-v3/contracts/dependencies/openzeppelin/contracts/IERC20Detailed.sol';
import {IPool} from '@aave/core-v3/contracts/interfaces/IPool.sol';
import {DataTypes} from '@aave/core-v3/contracts/protocol/libraries/types/DataTypes.sol';

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
interface FlashMinter {
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
contract ParaSwapDebtSwapAdapterV3GHO is ParaSwapDebtSwapAdapterV3, IERC3156FlashBorrower {
  // GHO special case
  address public constant GHO = 0x40D16FC0246aD3160Ccc09B8D0D3A2cD28aE6C2f;
  FlashMinter public constant GHO_FLASH_MINTER =
    FlashMinter(0xb639D208Bcf0589D54FaC24E655C79EC529762B8);

  constructor(
    IPoolAddressesProvider addressesProvider,
    address pool,
    IParaSwapAugustusRegistry augustusRegistry,
    address owner
  ) ParaSwapDebtSwapAdapterV3(addressesProvider, pool, augustusRegistry, owner) {}

  /// @dev ERC-3156 Flash loan callback (in this case flash mint)
  function onFlashLoan(
    address initiator,
    address token,
    uint256 amount,
    uint256 fee,
    bytes calldata data
  ) external override returns (bytes32) {
    require(msg.sender == address(GHO_FLASH_MINTER), 'SENDER_MUST_BE_MINTER');
    require(initiator == address(this), 'INITIATOR_MUST_BE_THIS');
    require(token == GHO, 'MUST_BE_GHO');
    FlashParams memory swapParams = abi.decode(data, (FlashParams));
    uint256 amountSold = _swapAndRepay(swapParams, IERC20Detailed(token), amount);
    POOL.borrow(GHO, (amountSold + fee), 1, REFERRER, swapParams.user);

    return keccak256('ERC3156FlashBorrower.onFlashLoan');
  }

  function _flash(
    FlashParams memory flashParams,
    DebtSwapParams memory debtSwapParams
  ) internal override {
    if (debtSwapParams.newDebtAsset == GHO) {
      GHO_FLASH_MINTER.flashLoan(
        IERC3156FlashBorrower(address(this)),
        GHO,
        debtSwapParams.maxNewDebtAmount,
        abi.encode(flashParams)
      );
    } else {
      super._flash(flashParams, debtSwapParams);
    }
  }
}
