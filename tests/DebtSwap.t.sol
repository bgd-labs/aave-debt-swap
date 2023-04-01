// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IERC20Detailed} from '@aave/core-v3/contracts/dependencies/openzeppelin/contracts/IERC20Detailed.sol';
import {IPoolAddressesProvider} from '@aave/core-v3/contracts/interfaces/IPoolAddressesProvider.sol';
import {AaveV3Ethereum, AaveV3EthereumAssets} from 'aave-address-book/AaveV3Ethereum.sol';
import {BaseTest} from './utils/BaseTest.sol';
import {ICreditDelegationToken} from '../src/interfaces/ICreditDelegationToken.sol';
import {ParaSwapDebtSwapAdapter} from '../src/contracts/ParaSwapDebtSwapAdapter.sol';
import {AugustusRegistry} from '../src/lib/AugustusRegistry.sol';

contract DebtSwapTest is BaseTest {
  ParaSwapDebtSwapAdapter internal debtSwapAdapter;

  function setUp() public override {
    super.setUp();
    vm.createSelectFork(vm.rpcUrl('mainnet'), 16956285);

    debtSwapAdapter = new ParaSwapDebtSwapAdapter(
      IPoolAddressesProvider(address(AaveV3Ethereum.POOL_ADDRESSES_PROVIDER)),
      AugustusRegistry.ETHEREUM,
      AaveV3Ethereum.ACL_ADMIN
    );
  }

  /**
   * 1. supply 200000 DAI
   * 2. borrow 100 DAI
   * 3. swap whole DAI debt to LUSD debt
   */
  function test_debtSwap_noPermit() public {
    vm.startPrank(user);
    address debtAsset = AaveV3EthereumAssets.DAI_UNDERLYING;
    address debtToken = AaveV3EthereumAssets.DAI_V_TOKEN;
    address newDebtAsset = AaveV3EthereumAssets.LINK_UNDERLYING;
    address newDebtToken = AaveV3EthereumAssets.LINK_V_TOKEN;

    uint256 supplyAmount = 200000 ether;
    uint256 borrowAmount = 100 ether;

    _supply(AaveV3Ethereum.POOL, supplyAmount, debtAsset);
    _borrow(AaveV3Ethereum.POOL, borrowAmount, debtAsset);

    // add some margin to account for accumulated debt
    uint256 repayAmount = borrowAmount / 2;
    PsPResponse memory psp = _fetchPSPRoute(
      newDebtAsset,
      debtAsset,
      repayAmount,
      user,
      false,
      false
    );

    ICreditDelegationToken(newDebtToken).approveDelegation(address(debtSwapAdapter), psp.srcAmount);

    ParaSwapDebtSwapAdapter.FlashloanParams memory flashParams = ParaSwapDebtSwapAdapter
      .FlashloanParams(newDebtAsset, psp.srcAmount, 2);

    ParaSwapDebtSwapAdapter.SwapParams memory pspParams = ParaSwapDebtSwapAdapter.SwapParams(
      IERC20Detailed(debtAsset),
      repayAmount,
      2,
      abi.encode(psp.swapCalldata, psp.augustus)
    );

    uint256 vDEBT_TOKENBalanceBefore = IERC20Detailed(debtToken).balanceOf(user);

    debtSwapAdapter.swapDebt(flashParams, pspParams);

    uint256 vDEBT_TOKENBalanceAfter = IERC20Detailed(debtToken).balanceOf(user);
    uint256 vNEWDEBT_TOKENBalanceAfter = IERC20Detailed(newDebtToken).balanceOf(user);
    assertEq(vDEBT_TOKENBalanceAfter, vDEBT_TOKENBalanceBefore - repayAmount);
    assertLe(vNEWDEBT_TOKENBalanceAfter, psp.srcAmount);
  }
}
