// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;
import {IParaSwapAugustusRegistry} from '../interfaces/IParaSwapAugustusRegistry.sol';

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

  IParaSwapAugustusRegistry public constant BSC =
    IParaSwapAugustusRegistry(0x05b4486f643914a818eD93Afc07457e9074be211);

  IParaSwapAugustusRegistry public constant BASE = IParaSwapAugustusRegistry();
}
