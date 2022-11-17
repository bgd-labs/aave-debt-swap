// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.10;

import {IPoolAddressesProvider} from '@aave/core-v3/contracts/interfaces/IPoolAddressesProvider.sol';
import {IPool} from '@aave/core-v3/contracts/interfaces/IPool.sol';

/**
 * @dev Altered version which does not enforce implementation of FlashLoanReceiver or FlashLoanReceiverSimple.
 * This is a workaround as there are no generics in solidity.
 * @title FlashLoanReceiverBase
 * @author BGD
 * @notice Base contract to develop a flashloan-receiver contract.
 */
abstract contract ReducedFlashLoanReceiverBase {
  IPoolAddressesProvider public immutable ADDRESSES_PROVIDER;
  IPool public immutable POOL;

  constructor(IPoolAddressesProvider provider) {
    ADDRESSES_PROVIDER = provider;
    POOL = IPool(provider.getPool());
  }
}
