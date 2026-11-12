// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {TowerStructs} from "./TowerStructs.sol";
import {IUrmFortressTower} from "./IUrmFortressTower.sol";

// the fURM wrapper hook surface beyond Uniswap's IHooks, plus the Fortress tower hooks; implemented by FountainUrmHook
interface IFountainUrmHook is IUrmFortressTower {
  event ConfigChanged(TowerStructs.FountainHookConfig config);
  event Collected(uint256 furmRedeemed, uint256 urmRecovered);
  event Burned(uint256 urm);
  event Synced(uint256 urmBalance, uint256 furmBalance);
  event TowerClosed(uint256 urmBurned);

  function withdrawToken(address tokenAdr) external;
  function setConfigs(TowerStructs.FountainHookConfig calldata newConfig) external;
  function collect() external;
  function closeTower() external;
  function getState() external view returns (TowerStructs.FountainHookGetState memory);
}
