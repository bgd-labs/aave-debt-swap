// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import 'forge-std/Test.sol';
import {ParaSwapLiquiditySwapAdapter} from '../src/contracts/ParaSwapLiquiditySwapAdapter.sol';
import {ParaSwapRepayAdapter} from '../src/contracts/ParaSwapRepayAdapter.sol';

contract DebtSwapTest is Test {
  ParaSwapLiquiditySwapAdapter public lqSwapAdapter;
  ParaSwapRepayAdapter public repayAdapter;

  function setUp() public {
    vm.createSelectFork(vm.rpcUrl('ethereum'));
    lqSwapAdapter = new ParaSwapLiquiditySwapAdapter();
    repayAdapter = new ParaSwapRepayAdapter();
  }

  function _fetchPSPRoute(
    address from,
    address to,
    uint256 amount,
    address user
  ) internal returns (address, bytes memory) {
    string[] memory inputs = new string[](7);
    inputs[0] = 'node';
    inputs[1] = './scripts/test.js';
    inputs[2] = vm.toString(block.chainid);
    inputs[3] = vm.toString(from);
    inputs[4] = vm.toString(to);
    inputs[5] = vm.toString(amount);
    inputs[6] = vm.toString(user);
    bytes memory res = vm.ffi(inputs);
    return abi.decode(res, (address, bytes));
  }

  function test_debtSwap() public {
    (address augustus, bytes memory data) = _fetchPSPRoute(
      0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE,
      0x6B175474E89094C44Da98b954EedeAC495271d0F,
      2 ether,
      address(this)
    );
  }
}
