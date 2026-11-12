// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "./IERC20.sol";

// the URM surface the hook uses beyond ERC-20: burning Fortress-minted supply
interface IUrm is IERC20 {
  function burn(uint256 amount) external;
}
