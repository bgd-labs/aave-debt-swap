// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {IPoolAddressesProvider} from '@aave/core-v3/contracts/interfaces/IPoolAddressesProvider.sol';
import {ArbitrumScript, EthereumScript, PolygonScript, AvalancheScript} from 'aave-helpers/../scripts/Utils.s.sol';
import {AaveGovernanceV2} from 'aave-address-book/AaveGovernanceV2.sol';
import {AaveV2Ethereum} from 'aave-address-book/AaveV2Ethereum.sol';
import {AaveV3Ethereum} from 'aave-address-book/AaveV3Ethereum.sol';
import {AaveV2Polygon} from 'aave-address-book/AaveV2Polygon.sol';
import {AaveV2Avalanche} from 'aave-address-book/AaveV2Avalanche.sol';
import {ParaSwapDebtSwapAdapterV3} from '../src/contracts/ParaSwapDebtSwapAdapterV3.sol';
import {ParaSwapDebtSwapAdapterV2} from '../src/contracts/ParaSwapDebtSwapAdapterV2.sol';
import {AugustusRegistry} from '../src/lib/AugustusRegistry.sol';

contract EthereumV2 is EthereumScript {
  function run() external broadcast {
    new ParaSwapDebtSwapAdapterV2(
      IPoolAddressesProvider(address(AaveV2Ethereum.POOL_ADDRESSES_PROVIDER)),
      address(AaveV2Ethereum.POOL),
      AugustusRegistry.ETHEREUM,
      AaveGovernanceV2.SHORT_EXECUTOR
    );
  }
}

contract EthereumV3 is EthereumScript {
  function run() external broadcast {
    new ParaSwapDebtSwapAdapterV3(
      IPoolAddressesProvider(address(AaveV3Ethereum.POOL_ADDRESSES_PROVIDER)),
      address(AaveV3Ethereum.POOL),
      AugustusRegistry.ETHEREUM,
      AaveGovernanceV2.SHORT_EXECUTOR
    );
  }
}

contract PolygonV2 is PolygonScript {
  function run() external broadcast {
    new ParaSwapDebtSwapAdapterV2(
      IPoolAddressesProvider(address(AaveV2Polygon.POOL_ADDRESSES_PROVIDER)),
      address(AaveV2Polygon.POOL),
      AugustusRegistry.POLYGON,
      AaveGovernanceV2.POLYGON_BRIDGE_EXECUTOR
    );
  }
}

contract AvalancheV2 is AvalancheScript {
  function run() external broadcast {
    new ParaSwapDebtSwapAdapterV2(
      IPoolAddressesProvider(address(AaveV2Avalanche.POOL_ADDRESSES_PROVIDER)),
      address(AaveV2Avalanche.POOL),
      AugustusRegistry.AVALANCHE,
      0xa35b76E4935449E33C56aB24b23fcd3246f13470 // guardian
    );
  }
}
