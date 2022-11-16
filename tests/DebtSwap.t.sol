// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import 'forge-std/Test.sol';

contract DebtSwapTest is Test {
  function setUp() public {}

  function _fetchPSPRoute(
    uint256 chainId,
    address from,
    address to,
    uint256 amount,
    address user
  ) internal returns (address, bytes memory) {
    string[] memory inputs = new string[](7);
    inputs[0] = 'node';
    inputs[1] = './scripts/test.js';
    inputs[2] = vm.toString(chainId);
    inputs[3] = vm.toString(from);
    inputs[4] = vm.toString(to);
    inputs[5] = vm.toString(amount);
    inputs[6] = vm.toString(user);
    bytes memory res = vm.ffi(inputs);
    return abi.decode(res, (address, bytes));
  }

  function test_debtSwap() public {
    (address augustus, bytes memory data) = _fetchPSPRoute(
      1,
      0xEeeeeEeeeEeEeeEeEeEeeEEEeeeeEeeeeeeeEEeE,
      0x6B175474E89094C44Da98b954EedeAC495271d0F,
      2 ether,
      address(this)
    );
    console.log(augustus);
  }
}
