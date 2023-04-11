// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import 'forge-std/Test.sol';
import {AaveV3Polygon} from 'aave-address-book/AaveV3Polygon.sol';
import {DataTypes} from 'aave-address-book/AaveV3.sol';
import {IPoolAddressesProvider} from '@aave/core-v3/contracts/interfaces/IPoolAddressesProvider.sol';
import {IERC20Detailed} from '@aave/core-v3/contracts/dependencies/openzeppelin/contracts/IERC20Detailed.sol';
import {IPool} from '@aave/core-v3/contracts/interfaces/IPool.sol';

contract BaseTest is Test {
  struct PsPResponse {
    address augustus;
    bytes swapCalldata;
    uint256 srcAmount;
    uint256 destAmount;
    uint256 offset;
  }

  address public user;
  uint256 internal userPrivateKey;

  uint256 constant MAX_SLIPPAGE = 3;

  function setUp() public virtual {
    userPrivateKey = 0xA11CE;
    user = address(vm.addr(userPrivateKey));
  }

  function _fetchPSPRoute(
    address from,
    address to,
    uint256 amount,
    address userAddress,
    bool sell,
    bool max
  ) internal returns (PsPResponse memory) {
    string[] memory inputs = new string[](13);
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
    inputs[12] = vm.toString(block.number);

    bytes memory res = vm.ffi(inputs);
    return abi.decode(res, (PsPResponse));
  }
}
