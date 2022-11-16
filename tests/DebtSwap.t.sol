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

contract DebtSwapTest is Test {
  ParaSwapLiquiditySwapAdapter public lqSwapAdapter;
  ParaSwapRepayAdapter public repayAdapter;

  address public constant BAL = 0x9a71012B13CA4d3D0Cdc72A177DF3ef03b0E76A3;
  address public constant A_BAL = 0x8ffDf2DE812095b1D19CB146E4c004587C0A0692;
  address public constant DAI = 0x8f3Cf7ad23Cd3CaDbD9735AFf958023239c6A063;
  address public constant A_DAI = 0x82E64f49Ed5EC1bC6e43DAD4FC8Af9bb3A2312EE;

  address public user;

  function setUp() public {
    vm.createSelectFork(vm.rpcUrl('polygon'), 35683611);
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
    address swapUser
  ) internal returns (address, bytes memory, uint256) {
    string[] memory inputs = new string[](7);
    inputs[0] = 'node';
    inputs[1] = './scripts/test.js';
    inputs[2] = vm.toString(block.chainid);
    inputs[3] = vm.toString(from);
    inputs[4] = vm.toString(to);
    inputs[5] = vm.toString(amount);
    inputs[6] = vm.toString(swapUser);
    bytes memory res = vm.ffi(inputs);
    return abi.decode(res, (address, bytes, uint256));
  }

  function test_swapCollateral_leaveDust_noPermit() public {
    uint256 amount = 10 ether;
    deal(BAL, user, amount);
    IERC20Detailed(BAL).approve(address(AaveV3Polygon.POOL), amount);
    AaveV3Polygon.POOL.supply(BAL, amount, user, 0);

    skip(100);

    (
      address augustus,
      bytes memory swapCalldata,
      uint256 amountOut
    ) = _fetchPSPRoute(BAL, DAI, amount, user);
    BaseParaSwapAdapter.PermitSignature memory signature;

    IERC20Detailed(A_BAL).approve(address(lqSwapAdapter), amount);
    lqSwapAdapter.swapAndDeposit(
      IERC20Detailed(BAL),
      IERC20Detailed(DAI),
      amount,
      (amountOut * 99) / 100, // 1% slippage
      0,
      swapCalldata,
      IParaSwapAugustus(augustus),
      signature
    );

    uint256 aBALBalanceAfter = IERC20Detailed(A_BAL).balanceOf(user);
    uint256 aDAIBalanceAfter = IERC20Detailed(A_DAI).balanceOf(user);
    assertEq(aBALBalanceAfter == 0, false);
    assertApproxEqAbs(aBALBalanceAfter, 0, 0.00001 ether);
    assertApproxEqAbs(aDAIBalanceAfter, amountOut, amountOut / 100);
  }
}
