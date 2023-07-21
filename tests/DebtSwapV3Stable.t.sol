// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IERC20Detailed} from '@aave/core-v3/contracts/dependencies/openzeppelin/contracts/IERC20Detailed.sol';
import {IERC20WithPermit} from 'solidity-utils/contracts/oz-common/interfaces/IERC20WithPermit.sol';
import {IPoolAddressesProvider} from '@aave/core-v3/contracts/interfaces/IPoolAddressesProvider.sol';
import {AaveGovernanceV2} from 'aave-address-book/AaveGovernanceV2.sol';
import {AaveV3Arbitrum, AaveV3ArbitrumAssets, IPool} from 'aave-address-book/AaveV3Arbitrum.sol';
import {BaseTest} from './utils/BaseTest.sol';
import {ICreditDelegationToken} from '../src/interfaces/ICreditDelegationToken.sol';
import {IParaswapDebtSwapAdapter} from '../src/interfaces/IParaswapDebtSwapAdapter.sol';
import {ParaSwapDebtSwapAdapter} from '../src/contracts/ParaSwapDebtSwapAdapter.sol';
import {ParaSwapDebtSwapAdapterV3} from '../src/contracts/ParaSwapDebtSwapAdapterV3.sol';
import {AugustusRegistry} from '../src/lib/AugustusRegistry.sol';
import {SigUtils} from './utils/SigUtils.sol';

contract DebtSwapV3StableTest is BaseTest {
  ParaSwapDebtSwapAdapterV3 internal debtSwapAdapter;

  function setUp() public override {
    super.setUp();
    vm.createSelectFork(vm.rpcUrl('arbitrum'), 113419868);

    debtSwapAdapter = new ParaSwapDebtSwapAdapterV3(
      IPoolAddressesProvider(address(AaveV3Arbitrum.POOL_ADDRESSES_PROVIDER)),
      address(AaveV3Arbitrum.POOL),
      AugustusRegistry.ARBITRUM,
      AaveGovernanceV2.ARBITRUM_BRIDGE_EXECUTOR
    );
  }

  function test_debtSwap_swapAll_stableDebt() public {
    vm.startPrank(user);
    address debtAsset = AaveV3ArbitrumAssets.DAI_UNDERLYING;
    address debtToken = AaveV3ArbitrumAssets.DAI_S_TOKEN;
    address newDebtAsset = AaveV3ArbitrumAssets.LUSD_UNDERLYING;
    address newDebtToken = AaveV3ArbitrumAssets.LUSD_V_TOKEN;

    uint256 supplyAmount = 200000e6;
    uint256 borrowAmount = 1000 ether;

    _supply(AaveV3Arbitrum.POOL, supplyAmount, AaveV3ArbitrumAssets.USDCn_UNDERLYING);
    _borrow(AaveV3Arbitrum.POOL, borrowAmount, debtAsset, true);

    // add some margin to account for accumulated debt
    uint256 repayAmount = (borrowAmount * 101) / 100;
    PsPResponse memory psp = _fetchPSPRoute(
      newDebtAsset,
      debtAsset,
      repayAmount,
      user,
      false,
      true
    );

    skip(1 hours);

    ICreditDelegationToken(newDebtToken).approveDelegation(address(debtSwapAdapter), psp.srcAmount);

    IParaswapDebtSwapAdapter.DebtSwapParams memory debtSwapParams = IParaswapDebtSwapAdapter
      .DebtSwapParams({
        debtAsset: debtAsset,
        debtRepayAmount: type(uint256).max,
        debtRateMode: 1,
        newDebtAsset: newDebtAsset,
        maxNewDebtAmount: psp.srcAmount,
        paraswapData: abi.encode(psp.swapCalldata, psp.augustus),
        offset: psp.offset
      });

    IParaswapDebtSwapAdapter.CreditDelegationInput memory cd;
    debtSwapAdapter.swapDebt(debtSwapParams, cd);

    uint256 vDEBT_TOKENBalanceAfter = IERC20Detailed(debtToken).balanceOf(user);
    uint256 vNEWDEBT_TOKENBalanceAfter = IERC20Detailed(newDebtToken).balanceOf(user);
    assertEq(vDEBT_TOKENBalanceAfter, 0);
    assertLe(vNEWDEBT_TOKENBalanceAfter, psp.srcAmount);
    _invariant(address(debtSwapAdapter), debtAsset, newDebtAsset);
  }

  function _supply(IPool pool, uint256 amount, address asset) internal {
    deal(asset, user, amount);
    IERC20Detailed(asset).approve(address(pool), amount);
    pool.supply(asset, amount, user, 0);
  }

  function _borrow(IPool pool, uint256 amount, address asset) internal {
    pool.borrow(asset, amount, 2, 0, user);
  }

  function _borrow(IPool pool, uint256 amount, address asset, bool stable) internal {
    pool.borrow(asset, amount, stable ? 1 : 2, 0, user);
  }
}
