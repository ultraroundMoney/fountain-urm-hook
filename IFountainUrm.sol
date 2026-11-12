// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// the FountainUrm surface the hook uses beyond IERC4626: the net URM the vault can pay out right now (its balance less
// the withdraw fee, capped by the remaining withdrawal window). The full interface lives with the vault on branch urm-fountain
interface IFountainUrm {
  function payableUrm() external view returns (uint256);
}
