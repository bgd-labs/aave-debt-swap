// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import 'forge-std/Test.sol';
import {AaveV3Polygon} from 'aave-address-book/AaveV3Polygon.sol';
import {DataTypes} from 'aave-address-book/AaveV3.sol';
import {IPoolAddressesProvider} from '@aave/core-v3/contracts/interfaces/IPoolAddressesProvider.sol';
import {IERC20Detailed} from '@aave/core-v3/contracts/dependencies/openzeppelin/contracts/IERC20Detailed.sol';
import {IERC20WithPermit} from '@aave/core-v3/contracts/interfaces/IERC20WithPermit.sol';
import {IAToken} from '@aave/core-v3/contracts/interfaces/IAToken.sol';
import {ParaSwapLiquiditySwapAdapter} from '../src/contracts/ParaSwapLiquiditySwapAdapter.sol';
import {ParaSwapRepayAdapter} from '../src/contracts/ParaSwapRepayAdapter.sol';
import {ParaSwapDebtSwapAdapter} from '../src/contracts/ParaSwapDebtSwapAdapter.sol';
import {IParaSwapAugustus} from '../src/interfaces/IParaSwapAugustus.sol';
import {IParaSwapAugustusRegistry} from '../src/interfaces/IParaSwapAugustusRegistry.sol';
import {BaseParaSwapAdapter} from '../src/contracts/BaseParaSwapAdapter.sol';
import {SigUtils} from './utils/SigUtils.sol';

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
  struct PsPResponse {
    address augustus;
    bytes swapCalldata;
    uint256 srcAmount;
    uint256 destAmount;
    uint256 offset;
  }

  ParaSwapLiquiditySwapAdapter public lqSwapAdapter;
  ParaSwapRepayAdapter public repayAdapter;
  ParaSwapDebtSwapAdapter public debtSwapAdapter;

  address public constant SRC_TOKEN =
    0x2791Bca1f2de4661ED88A30C99A7a9449Aa84174;
  address public constant DEST_TOKEN =
    0x8f3Cf7ad23Cd3CaDbD9735AFf958023239c6A063;

  DataTypes.ReserveData internal srcReserveData;
  DataTypes.ReserveData internal destReserveData;

  address public user;
  uint256 internal userPrivateKey;

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
    debtSwapAdapter = new ParaSwapDebtSwapAdapter(
      IPoolAddressesProvider(address(AaveV3Polygon.POOL_ADDRESSES_PROVIDER)),
      AugustusRegistry.POLYGON,
      AaveV3Polygon.ACL_ADMIN
    );
    userPrivateKey = 0xA11CE;
    user = address(vm.addr(userPrivateKey));
    vm.startPrank(user);
    _setupTokens();
  }

  function _setupTokens() internal {
    srcReserveData = AaveV3Polygon.POOL.getReserveData(SRC_TOKEN);
    destReserveData = AaveV3Polygon.POOL.getReserveData(DEST_TOKEN);
  }

  function _fetchPSPRoute(
    address from,
    address to,
    uint256 amount,
    address userAddress,
    bool sell,
    bool max
  ) internal returns (PsPResponse memory) {
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
    return abi.decode(res, (PsPResponse));
  }

  function _supply(uint256 amount, address asset) internal {
    deal(asset, user, amount);
    IERC20Detailed(asset).approve(address(AaveV3Polygon.POOL), amount);
    AaveV3Polygon.POOL.supply(asset, amount, user, 0);
  }

  function _borrow(uint256 amount, address asset) internal {
    AaveV3Polygon.POOL.borrow(asset, amount, 2, 0, user);
  }

  function _flashSimple(
    address receiver,
    uint256 amount,
    address asset,
    bytes memory calldatas
  ) internal {
    AaveV3Polygon.POOL.flashLoanSimple(receiver, asset, amount, calldatas, 0);
  }

  function _flash(
    address receiver,
    uint256 amount,
    address asset,
    uint256 interestRateMode,
    bytes memory calldatas
  ) internal {
    address[] memory assets = new address[](1);
    assets[0] = asset;
    uint256[] memory amounts = new uint256[](1);
    amounts[0] = amount;
    uint256[] memory interestRateModes = new uint256[](1);
    interestRateModes[0] = interestRateMode;
    AaveV3Polygon.POOL.flashLoan(
      receiver,
      assets,
      amounts,
      interestRateModes,
      user,
      calldatas,
      0
    );
  }

  function test_swapCollateral_leaveDust_noPermit() public {
    uint256 amount = 600000000;
    _supply(amount, SRC_TOKEN);

    skip(100);
    PsPResponse memory psp = _fetchPSPRoute(
      SRC_TOKEN,
      DEST_TOKEN,
      amount,
      user,
      true,
      false
    );
    BaseParaSwapAdapter.PermitSignature memory signature;

    IERC20Detailed(srcReserveData.aTokenAddress).approve(
      address(lqSwapAdapter),
      amount
    );
    lqSwapAdapter.swapAndDeposit(
      IERC20Detailed(SRC_TOKEN),
      IERC20Detailed(DEST_TOKEN),
      amount,
      psp.destAmount,
      0,
      psp.swapCalldata,
      IParaSwapAugustus(psp.augustus),
      signature
    );

    uint256 aSRC_TOKENBalanceAfter = IERC20Detailed(
      srcReserveData.aTokenAddress
    ).balanceOf(user);
    uint256 aDEST_TOKENBalanceAfter = IERC20Detailed(
      destReserveData.aTokenAddress
    ).balanceOf(user);
    assertEq(aSRC_TOKENBalanceAfter == 0, false);
    assertApproxEqAbs(aSRC_TOKENBalanceAfter, 0, 100);
    assertGt(aDEST_TOKENBalanceAfter, psp.destAmount);
  }

  function test_swapCollateral_noPermit() public {
    uint256 amount = 600000000;
    _supply(amount, SRC_TOKEN);

    skip(100);
    uint256 amountWithMargin = (amount * 101) / 100;
    PsPResponse memory psp = _fetchPSPRoute(
      SRC_TOKEN,
      DEST_TOKEN,
      amountWithMargin,
      user,
      true,
      true
    );
    BaseParaSwapAdapter.PermitSignature memory signature;

    IERC20Detailed(srcReserveData.aTokenAddress).approve(
      address(lqSwapAdapter),
      type(uint256).max
    );
    lqSwapAdapter.swapAndDeposit(
      IERC20Detailed(SRC_TOKEN),
      IERC20Detailed(DEST_TOKEN),
      amountWithMargin,
      psp.destAmount,
      psp.offset,
      psp.swapCalldata,
      IParaSwapAugustus(psp.augustus),
      signature
    );

    uint256 aSRC_TOKENBalanceAfter = IERC20Detailed(
      srcReserveData.aTokenAddress
    ).balanceOf(user);
    uint256 aDEST_TOKENBalanceAfter = IERC20Detailed(
      destReserveData.aTokenAddress
    ).balanceOf(user);
    assertEq(aSRC_TOKENBalanceAfter, 0);
    assertGt(aDEST_TOKENBalanceAfter, psp.destAmount);
  }

  function test_swapCollateral() public {
    uint256 amount = 600000000;
    _supply(amount, SRC_TOKEN);

    skip(100);
    uint256 amountWithMargin = (amount * 101) / 100;
    PsPResponse memory psp = _fetchPSPRoute(
      SRC_TOKEN,
      DEST_TOKEN,
      amountWithMargin,
      user,
      true,
      true
    );

    BaseParaSwapAdapter.PermitSignature memory signature = SigUtils.getPermit(
      vm,
      user,
      userPrivateKey,
      SRC_TOKEN,
      amountWithMargin
    );

    lqSwapAdapter.swapAndDeposit(
      IERC20Detailed(SRC_TOKEN),
      IERC20Detailed(DEST_TOKEN),
      amountWithMargin,
      psp.destAmount,
      psp.offset,
      psp.swapCalldata,
      IParaSwapAugustus(psp.augustus),
      signature
    );

    uint256 aSRC_TOKENBalanceAfter = IERC20Detailed(
      srcReserveData.aTokenAddress
    ).balanceOf(user);
    uint256 aDEST_TOKENBalanceAfter = IERC20Detailed(
      destReserveData.aTokenAddress
    ).balanceOf(user);
    assertEq(aSRC_TOKENBalanceAfter, 0);
    assertGt(aDEST_TOKENBalanceAfter, psp.destAmount);
  }

  // function test_swapCollateral_noPermit_flashloan() public {
  //   uint256 amount = 600000000;
  //   _supply(amount, SRC_TOKEN);

  //   skip(100);
  //   uint256 amountWithMargin = (amount * 101) / 100;
  //   (
  //     address augustus,
  //     bytes memory swapCalldata,
  //     uint256 srcAmount,
  //     uint256 destAmount,
  //     uint256 offset
  //   ) = _fetchPSPRoute(
  //       SRC_TOKEN,
  //       DEST_TOKEN,
  //       amountWithMargin,
  //       user,
  //       true,
  //       true
  //     );
  //   BaseParaSwapAdapter.PermitSignature memory signature;

  //   IERC20Detailed(srcReserveData.aTokenAddress).approve(
  //     address(lqSwapAdapter),
  //     type(uint256).max
  //   );
  //   bytes memory calldatas = abi.encode(
  //     IERC20Detailed(DEST_TOKEN),
  //     destAmount,
  //     offset,
  //     swapCalldata,
  //     IParaSwapAugustus(augustus),
  //     (signature)
  //   );
  //   _flashSimple(
  //     address(lqSwapAdapter),
  //     (amountWithMargin * 101) / 100,
  //     SRC_TOKEN,
  //     calldatas
  //   );

  //   uint256 aSRC_TOKENBalanceAfter = IERC20Detailed(
  //     srcReserveData.aTokenAddress
  //   ).balanceOf(user);
  //   uint256 aDEST_TOKENBalanceAfter = IERC20Detailed(
  //     destReserveData.aTokenAddress
  //   ).balanceOf(user);
  //   assertEq(aSRC_TOKENBalanceAfter, 0);
  //   assertGt(aDEST_TOKENBalanceAfter, destAmount);
  // }

  // function test_repayCollateral_leaveDust_noPermit() public {
  //   uint256 supplyAmount = 20000 ether;
  //   uint256 borrowAmount = 5000000;

  //   _supply(supplyAmount, DEST_TOKEN);
  //   _borrow(borrowAmount, SRC_TOKEN);

  //   skip(100);
  //   (
  //     address augustus,
  //     bytes memory swapCalldata,
  //     uint256 srcAmount,
  //     uint256 destAmount,

  //   ) = _fetchPSPRoute(DEST_TOKEN, SRC_TOKEN, borrowAmount, user, false, false);
  //   BaseParaSwapAdapter.PermitSignature memory signature;
  //   IERC20Detailed(destReserveData.aTokenAddress).approve(
  //     address(repayAdapter),
  //     supplyAmount
  //   );
  //   repayAdapter.swapAndRepay(
  //     IERC20Detailed(DEST_TOKEN),
  //     IERC20Detailed(SRC_TOKEN),
  //     srcAmount,
  //     borrowAmount,
  //     2,
  //     0,
  //     abi.encode(swapCalldata, augustus),
  //     signature
  //   );
  // }

  // /**
  //  * 1. supply 20000 DEST_TOKEN
  //  * 2. borrow 5 vSRC_TOKEN
  //  * 3. swap debt to 5 vDEST_TOKEN
  //  */
  // function test_debtSwap_noPermit() public {
  //   uint256 supplyAmount = 20000 ether;
  //   uint256 borrowAmount = 5000000;

  //   _supply(supplyAmount, DEST_TOKEN);
  //   _borrow(borrowAmount, SRC_TOKEN);

  //   // forward time to accumulate some debt
  //   skip(100);

  //   // add some margin to account for accumulated debt
  //   uint256 amountWithMargin = (borrowAmount * 101) / 100;
  //   (
  //     address augustus,
  //     bytes memory swapCalldata,
  //     uint256 srcAmount,
  //     uint256 destAmount,
  //     uint256 offset
  //   ) = _fetchPSPRoute(
  //       DEST_TOKEN,
  //       SRC_TOKEN,
  //       amountWithMargin,
  //       user,
  //       false,
  //       true
  //     );

  //   // execute flashloan
  //   bytes memory calldatas = abi.encode(
  //     IERC20Detailed(SRC_TOKEN),
  //     srcAmount,
  //     offset,
  //     2,
  //     abi.encode(swapCalldata, augustus)
  //   );
  //   _flash(address(debtSwapAdapter), srcAmount, DEST_TOKEN, 2, calldatas);

  //   uint256 vSRC_TOKENBalanceAfter = IERC20Detailed(
  //     srcReserveData.variableDebtTokenAddress
  //   ).balanceOf(user);
  //   uint256 vDEST_TOKENBalanceAfter = IERC20Detailed(
  //     destReserveData.variableDebtTokenAddress
  //   ).balanceOf(user);
  //   assertEq(vSRC_TOKENBalanceAfter, 0);
  //   assertEq(vDEST_TOKENBalanceAfter, srcAmount);
  // }
}
