// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import {IPRegistry} from "../src/IPRegistry.sol";
import {RoyaltyVault} from "../src/RoyaltyVault.sol";
import {LicenseManager} from "../src/LicenseManager.sol";
import {DisputeArbitrator} from "../src/DisputeArbitrator.sol";

contract Deploy is Script {
    function run() external {
        vm.startBroadcast();

        // 1. IPRegistry — no dependencies
        IPRegistry registry = new IPRegistry();
        console.log("IPRegistry:        ", address(registry));

        // 2. RoyaltyVault — needs IPRegistry address
        RoyaltyVault vault = new RoyaltyVault(address(registry));
        console.log("RoyaltyVault:      ", address(vault));

        // 3. LicenseManager — needs IPRegistry + RoyaltyVault addresses
        LicenseManager manager = new LicenseManager(address(registry), address(vault));
        console.log("LicenseManager:    ", address(manager));

        // 4. DisputeArbitrator — needs LicenseManager address
        //    constructor sets arbiter = msg.sender (the broadcaster)
        DisputeArbitrator arbitrator = new DisputeArbitrator(address(manager));
        console.log("DisputeArbitrator: ", address(arbitrator));

        // 5. Wire up: tell LicenseManager who the arbitrator is (one-time call)
        manager.setDisputeArbitrator(address(arbitrator));
        console.log("Arbitrator wired:  ", address(arbitrator));

        console.log("Deployer:          ", msg.sender);

        vm.stopBroadcast();
    }
}
