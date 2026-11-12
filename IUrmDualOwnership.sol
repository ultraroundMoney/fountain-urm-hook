// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

// the UrmDualOwnership surface the hook uses: the roles, read live
interface IUrmDualOwnership {
  function getOwners() external view returns (address owner1, address owner2);
  function getAutomator() external view returns (address);
  function getMultisig() external pure returns (address);
}
