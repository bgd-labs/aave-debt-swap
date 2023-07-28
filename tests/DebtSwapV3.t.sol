// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IERC20Detailed} from '@aave/core-v3/contracts/dependencies/openzeppelin/contracts/IERC20Detailed.sol';
import {IERC20WithPermit} from 'solidity-utils/contracts/oz-common/interfaces/IERC20WithPermit.sol';
import {IPoolAddressesProvider} from '@aave/core-v3/contracts/interfaces/IPoolAddressesProvider.sol';
import {Errors} from '@aave/core-v3/contracts/protocol/libraries/helpers/Errors.sol';
import {AaveGovernanceV2} from 'aave-address-book/AaveGovernanceV2.sol';
import {AaveV3Ethereum, AaveV3EthereumAssets, IPool} from 'aave-address-book/AaveV3Ethereum.sol';
import {BaseTest} from './utils/BaseTest.sol';
import {ICreditDelegationToken} from '../src/interfaces/ICreditDelegationToken.sol';
import {IParaswapDebtSwapAdapter} from '../src/interfaces/IParaswapDebtSwapAdapter.sol';
import {ParaSwapDebtSwapAdapter} from '../src/contracts/ParaSwapDebtSwapAdapter.sol';
import {ParaSwapDebtSwapAdapterV3} from '../src/contracts/ParaSwapDebtSwapAdapterV3.sol';
import {AugustusRegistry} from '../src/lib/AugustusRegistry.sol';
import {SigUtils} from './utils/SigUtils.sol';

import 'forge-std/console2.sol';

contract DebtSwapV3Test is BaseTest {
  ParaSwapDebtSwapAdapterV3 internal debtSwapAdapter;

  function setUp() public override {
    super.setUp();
    vm.createSelectFork(vm.rpcUrl('mainnet'), 17786869);

    debtSwapAdapter = new ParaSwapDebtSwapAdapterV3(
      IPoolAddressesProvider(address(AaveV3Ethereum.POOL_ADDRESSES_PROVIDER)),
      address(AaveV3Ethereum.POOL),
      AugustusRegistry.ETHEREUM,
      AaveGovernanceV2.SHORT_EXECUTOR
    );
  }

  /**
   * 1. supply 200000 DAI
   * 2. borrow 100 DAI
   * 3. swap whole DAI debt to LUSD debt
   */
  function test_debtSwap_swapHalf() public {
    vm.startPrank(user);
    address debtAsset = AaveV3EthereumAssets.DAI_UNDERLYING;
    address debtToken = AaveV3EthereumAssets.DAI_V_TOKEN;
    address newDebtAsset = AaveV3EthereumAssets.LUSD_UNDERLYING;
    address newDebtToken = AaveV3EthereumAssets.LUSD_V_TOKEN;

    uint256 supplyAmount = 200000 ether;
    uint256 borrowAmount = 1000 ether;

    _supply(AaveV3Ethereum.POOL, supplyAmount, debtAsset);
    _borrow(AaveV3Ethereum.POOL, borrowAmount, debtAsset);

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

    IParaswapDebtSwapAdapter.DebtSwapParams memory debtSwapParams = IParaswapDebtSwapAdapter
      .DebtSwapParams({
        debtAsset: debtAsset,
        debtRepayAmount: repayAmount,
        debtRateMode: 2,
        newDebtAsset: newDebtAsset,
        maxNewDebtAmount: psp.srcAmount,
        extraCollateralAsset: address(0),
        extraCollateralAmount: 0,
        offset: psp.offset,
        paraswapData: abi.encode(psp.swapCalldata, psp.augustus)
      });

    uint256 vDEBT_TOKENBalanceBefore = IERC20Detailed(debtToken).balanceOf(user);

    IParaswapDebtSwapAdapter.CreditDelegationInput memory cd;
    debtSwapAdapter.swapDebt(debtSwapParams, cd);

    uint256 vDEBT_TOKENBalanceAfter = IERC20Detailed(debtToken).balanceOf(user);
    uint256 vNEWDEBT_TOKENBalanceAfter = IERC20Detailed(newDebtToken).balanceOf(user);
    assertApproxEqAbs(vDEBT_TOKENBalanceAfter, vDEBT_TOKENBalanceBefore - repayAmount, 1);
    assertLe(vNEWDEBT_TOKENBalanceAfter, psp.srcAmount);
    _invariant(address(debtSwapAdapter), debtAsset, newDebtAsset);
  }

  function test_debtSwap_swapAll() public {
    vm.startPrank(user);
    address debtAsset = AaveV3EthereumAssets.DAI_UNDERLYING;
    address debtToken = AaveV3EthereumAssets.DAI_V_TOKEN;
    address newDebtAsset = AaveV3EthereumAssets.LUSD_UNDERLYING;
    address newDebtToken = AaveV3EthereumAssets.LUSD_V_TOKEN;

    uint256 supplyAmount = 200000 ether;
    uint256 borrowAmount = 1000 ether;

    _supply(AaveV3Ethereum.POOL, supplyAmount, debtAsset);
    _borrow(AaveV3Ethereum.POOL, borrowAmount, debtAsset);

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
        debtRateMode: 2,
        newDebtAsset: newDebtAsset,
        maxNewDebtAmount: psp.srcAmount,
        extraCollateralAsset: address(0),
        extraCollateralAmount: 0,
        offset: psp.offset,
        paraswapData: abi.encode(psp.swapCalldata, psp.augustus)
      });

    IParaswapDebtSwapAdapter.CreditDelegationInput memory cd;
    debtSwapAdapter.swapDebt(debtSwapParams, cd);

    uint256 vDEBT_TOKENBalanceAfter = IERC20Detailed(debtToken).balanceOf(user);
    uint256 vNEWDEBT_TOKENBalanceAfter = IERC20Detailed(newDebtToken).balanceOf(user);
    assertEq(vDEBT_TOKENBalanceAfter, 0);
    assertLe(vNEWDEBT_TOKENBalanceAfter, psp.srcAmount);
    _invariant(address(debtSwapAdapter), debtAsset, newDebtAsset);
  }

  function test_debtSwap_swapAll_permit() public {
    vm.startPrank(user);
    address debtAsset = AaveV3EthereumAssets.DAI_UNDERLYING;
    address debtToken = AaveV3EthereumAssets.DAI_V_TOKEN;
    address newDebtAsset = AaveV3EthereumAssets.LUSD_UNDERLYING;
    address newDebtToken = AaveV3EthereumAssets.LUSD_V_TOKEN;

    uint256 supplyAmount = 200000 ether;
    uint256 borrowAmount = 1000 ether;

    _supply(AaveV3Ethereum.POOL, supplyAmount, debtAsset);
    _borrow(AaveV3Ethereum.POOL, borrowAmount, debtAsset);

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

    IParaswapDebtSwapAdapter.DebtSwapParams memory debtSwapParams = IParaswapDebtSwapAdapter
      .DebtSwapParams({
        debtAsset: debtAsset,
        debtRepayAmount: type(uint256).max,
        debtRateMode: 2,
        newDebtAsset: newDebtAsset,
        maxNewDebtAmount: psp.srcAmount,
        extraCollateralAsset: address(0),
        extraCollateralAmount: 0,
        offset: psp.offset,
        paraswapData: abi.encode(psp.swapCalldata, psp.augustus)
      });

    IParaswapDebtSwapAdapter.CreditDelegationInput memory cd = _getCDPermit(
      psp.srcAmount,
      newDebtToken
    );

    debtSwapAdapter.swapDebt(debtSwapParams, cd);

    uint256 vDEBT_TOKENBalanceAfter = IERC20Detailed(debtToken).balanceOf(user);
    uint256 vNEWDEBT_TOKENBalanceAfter = IERC20Detailed(newDebtToken).balanceOf(user);
    assertEq(vDEBT_TOKENBalanceAfter, 0);
    assertLe(vNEWDEBT_TOKENBalanceAfter, psp.srcAmount);
    _invariant(address(debtSwapAdapter), debtAsset, newDebtAsset);
  }

  function test_debtSwap_Extra_Collateral() public {
    // We'll use the debtAsset & supplyAmount as extra collateral too.
    address aToken = AaveV3EthereumAssets.DAI_A_TOKEN;
    address debtAsset = AaveV3EthereumAssets.DAI_UNDERLYING;
    address debtToken = AaveV3EthereumAssets.DAI_V_TOKEN;
    address newDebtAsset = AaveV3EthereumAssets.LUSD_UNDERLYING;
    address newDebtToken = AaveV3EthereumAssets.LUSD_V_TOKEN;

    uint256 supplyAmount = 100e18;
    uint256 borrowAmount = 67e18;
    uint256 withdrawAmount = supplyAmount - (borrowAmount * 10) / 8; // We want to end with 80% utilisation

    vm.startPrank(user);

    _supply(AaveV3Ethereum.POOL, supplyAmount, debtAsset);
    _borrow(AaveV3Ethereum.POOL, borrowAmount, debtAsset);

    vm.expectRevert(bytes(Errors.COLLATERAL_CANNOT_COVER_NEW_BORROW));
    _borrow(AaveV3Ethereum.POOL, 1e18, debtAsset);

    _withdraw(AaveV3Ethereum.POOL, withdrawAmount, debtAsset);

    vm.expectRevert(bytes(Errors.HEALTH_FACTOR_LOWER_THAN_LIQUIDATION_THRESHOLD));
    _borrow(AaveV3Ethereum.POOL, 1e18, debtAsset);

    // Swap debt
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
    IERC20Detailed(aToken).approve(address(debtSwapAdapter), supplyAmount);

    IParaswapDebtSwapAdapter.DebtSwapParams memory debtSwapParams = IParaswapDebtSwapAdapter
      .DebtSwapParams({
        debtAsset: debtAsset,
        debtRepayAmount: type(uint256).max,
        debtRateMode: 2,
        newDebtAsset: newDebtAsset,
        maxNewDebtAmount: psp.srcAmount,
        extraCollateralAsset: debtAsset,
        extraCollateralAmount: supplyAmount,
        offset: psp.offset,
        paraswapData: abi.encode(psp.swapCalldata, psp.augustus)
      });

    IParaswapDebtSwapAdapter.CreditDelegationInput memory cd;
    debtSwapAdapter.swapDebt(debtSwapParams, cd);

    console2.log('here');
  }

  function _getCDPermit(
    uint256 amount,
    address debtToken
  ) internal view returns (IParaswapDebtSwapAdapter.CreditDelegationInput memory) {
    IERC20WithPermit token = IERC20WithPermit(debtToken);
    SigUtils.CreditDelegation memory creditDelegation = SigUtils.CreditDelegation({
      delegatee: address(debtSwapAdapter),
      value: amount,
      nonce: token.nonces(user),
      deadline: type(uint256).max
    });

    bytes32 digest = SigUtils.getCreditDelegationTypedDataHash(
      creditDelegation,
      token.DOMAIN_SEPARATOR()
    );

    (uint8 v, bytes32 r, bytes32 s) = vm.sign(userPrivateKey, digest);

    return
      IParaswapDebtSwapAdapter.CreditDelegationInput({
        debtToken: ICreditDelegationToken(address(token)),
        value: amount,
        deadline: type(uint256).max,
        v: v,
        r: r,
        s: s
      });
  }

  function _supply(IPool pool, uint256 amount, address asset) internal {
    deal(asset, user, amount);
    IERC20Detailed(asset).approve(address(pool), amount);
    pool.supply(asset, amount, user, 0);
  }

  function _borrow(IPool pool, uint256 amount, address asset) internal {
    pool.borrow(asset, amount, 2, 0, user);
  }

  function _withdraw(IPool pool, uint256 amount, address asset) internal {
    pool.withdraw(asset, amount, user);
  }
}
