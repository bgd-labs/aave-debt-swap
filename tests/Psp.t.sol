// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import 'forge-std/Test.sol';
import {AaveV3Polygon} from 'aave-address-book/AaveV3Polygon.sol';
import {IPoolAddressesProvider} from '@aave/core-v3/contracts/interfaces/IPoolAddressesProvider.sol';
import {IERC20Detailed} from '@aave/core-v3/contracts/dependencies/openzeppelin/contracts/IERC20Detailed.sol';
import {ParaSwapLiquiditySwapAdapter} from '../src/contracts/ParaSwapLiquiditySwapAdapter.sol';
import {ParaSwapRepayAdapter} from '../src/contracts/ParaSwapRepayAdapter.sol';
import {IParaSwapAugustus} from '../src/contracts/interfaces/IParaSwapAugustus.sol';
import {IParaSwapAugustusRegistry} from '../src/contracts/interfaces/IParaSwapAugustusRegistry.sol';
import {BaseParaSwapAdapter} from '../src/contracts/BaseParaSwapAdapter.sol';

library AugustusRegistry {
  IParaSwapAugustusRegistry public constant ETHEREUM =
    IParaSwapAugustusRegistry(0xa68bEA62Dc4034A689AA0F58A76681433caCa663);

  IParaSwapAugustusRegistry public constant POLYGON =
    IParaSwapAugustusRegistry(0xca35a4866747Ff7A604EF7a2A7F246bb870f3ca1);

  IParaSwapAugustusRegistry public constant AVALANCHE =
    IParaSwapAugustusRegistry(0xfD1E5821F07F1aF812bB7F3102Bfd9fFb279513a);

  IParaSwapAugustusRegistry public constant ARBITRUM =
    IParaSwapAugustusRegistry(0xdC6E2b14260F972ad4e5a31c68294Fba7E720701);

  IParaSwapAugustusRegistry public constant OPTIMISM =
    IParaSwapAugustusRegistry(0x6e7bE86000dF697facF4396efD2aE2C322165dC3);
}

contract PspTest is Test {
  ParaSwapLiquiditySwapAdapter public lqSwapAdapter;
  ParaSwapRepayAdapter public repayAdapter;

  address public constant USDC = 0x2791Bca1f2de4661ED88A30C99A7a9449Aa84174;
  address public constant A_USDC = 0x625E7708f30cA75bfd92586e17077590C60eb4cD;
  address public constant DAI = 0x8f3Cf7ad23Cd3CaDbD9735AFf958023239c6A063;
  address public constant A_DAI = 0x82E64f49Ed5EC1bC6e43DAD4FC8Af9bb3A2312EE;

  address public user;

  uint256 constant MAX_SLIPPAGE = 3;

  function setUp() public {
    vm.createSelectFork(vm.rpcUrl('polygon'), 35724579);
    lqSwapAdapter = new ParaSwapLiquiditySwapAdapter(
      IPoolAddressesProvider(address(AaveV3Polygon.POOL_ADDRESSES_PROVIDER)),
      AugustusRegistry.POLYGON,
      AaveV3Polygon.ACL_ADMIN
    );
    repayAdapter = new ParaSwapRepayAdapter(
      IPoolAddressesProvider(address(AaveV3Polygon.POOL_ADDRESSES_PROVIDER)),
      AugustusRegistry.POLYGON,
      AaveV3Polygon.ACL_ADMIN
    );

    user = address(this);
    vm.startPrank(user);
  }

  function _fetchPSPRoute(
    address from,
    address to,
    uint256 amount,
    address userAddress,
    bool sell,
    bool max
  ) internal returns (address, bytes memory, uint256, uint256) {
    string[] memory inputs = new string[](12);
    inputs[0] = 'node';
    inputs[1] = './scripts/psp.js';
    inputs[2] = vm.toString(block.chainid);
    inputs[3] = vm.toString(from);
    inputs[4] = vm.toString(to);
    inputs[5] = vm.toString(amount);
    inputs[6] = vm.toString(userAddress);
    inputs[7] = sell ? 'SELL' : 'BUY';
    inputs[8] = vm.toString(MAX_SLIPPAGE);
    inputs[9] = vm.toString(max);
    inputs[10] = vm.toString(IERC20Detailed(from).decimals());
    inputs[11] = vm.toString(IERC20Detailed(to).decimals());
    bytes memory res = vm.ffi(inputs);
    return abi.decode(res, (address, bytes, uint256, uint256));
  }

  function _supply(uint256 amount, address asset) internal {
    deal(asset, user, amount);
    IERC20Detailed(asset).approve(address(AaveV3Polygon.POOL), amount);
    AaveV3Polygon.POOL.supply(asset, amount, user, 0);
  }

  function _borrow(uint256 amount, address asset) internal {
    AaveV3Polygon.POOL.borrow(asset, amount, 2, 0, user);
  }

  function test_swapCollateral_leaveDust_noPermit() public {
    uint256 amount = 600000000;
    _supply(amount, USDC);

    skip(100);
    (
      address augustus,
      bytes memory swapCalldata,
      uint256 srcAmount,
      uint256 destAmount
    ) = _fetchPSPRoute(USDC, DAI, amount, user, true, false);
    BaseParaSwapAdapter.PermitSignature memory signature;

    IERC20Detailed(A_USDC).approve(address(lqSwapAdapter), amount);
    lqSwapAdapter.swapAndDeposit(
      IERC20Detailed(USDC),
      IERC20Detailed(DAI),
      amount,
      destAmount,
      0,
      swapCalldata,
      IParaSwapAugustus(augustus),
      signature
    );

    uint256 aUSDCBalanceAfter = IERC20Detailed(A_USDC).balanceOf(user);
    uint256 aDAIBalanceAfter = IERC20Detailed(A_DAI).balanceOf(user);
    assertEq(aUSDCBalanceAfter == 0, false);
    assertApproxEqAbs(aUSDCBalanceAfter, 0, 100);
    assertGt(aDAIBalanceAfter, destAmount);
  }

  function test_repayCollateral_leaveDust_noPermit() public {
    uint256 supplyAmount = 20000 ether;
    uint256 borrowAmount = 5000000;

    _supply(supplyAmount, DAI);
    _borrow(borrowAmount, USDC);

    skip(100);
    (
      address augustus,
      bytes memory swapCalldata,
      uint256 srcAmount,
      uint256 destAmount
    ) = _fetchPSPRoute(DAI, USDC, borrowAmount, user, false, false);
    BaseParaSwapAdapter.PermitSignature memory signature;
    IERC20Detailed(A_DAI).approve(address(repayAdapter), supplyAmount);
    repayAdapter.swapAndRepay(
      IERC20Detailed(DAI),
      IERC20Detailed(USDC),
      srcAmount,
      borrowAmount,
      2,
      0,
      abi.encode(swapCalldata, augustus),
      signature
    );
  }
}
