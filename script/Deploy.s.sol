// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import "forge-std/Script.sol";
import {AaveV3Vault} from "../src/AaveV3Vault.sol";

contract Deploy is Script {
    // Set this for your target network before running
    address constant POOL = address(0); // e.g., Aave V3 Pool address

    function run() external {
        vm.startBroadcast();
        new AaveV3Vault(POOL);
        vm.stopBroadcast();
    }
}
