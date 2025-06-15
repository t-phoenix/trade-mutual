// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {Script} from "../lib/forge-std/src/Script.sol";
import {MockUSDT} from "../src/MockUSDT.sol";
import {InvestmentPoolToken} from "../src/InvestmentPoolToken.sol";
import {InvestmentPoolManager} from "../src/InvestmentPoolManager.sol";
import {console} from "../lib/forge-std/src/console.sol";

contract DeployInvestmentPool is Script {
    function run() external {
        // Broadcast all transactions
        vm.startBroadcast();

        // Deploy Mock USDT
        MockUSDT usdt = new MockUSDT();

        // Deploy Pool Token (deployer is admin)
        InvestmentPoolToken poolToken = new InvestmentPoolToken("Investment Pool Token", "IPT", msg.sender);

        // Deploy InvestmentPoolManager
        // Example config: threshold = 1000e6 (USDT has 6 decimals), lockPeriod = 7 days, multisig = deployer
        uint256 threshold = 1000e6;
        uint256 lockPeriod = 7 days;
        address multisig = msg.sender;
        InvestmentPoolManager manager = new InvestmentPoolManager(
            address(usdt),
            address(poolToken),
            multisig,
            threshold,
            lockPeriod,
            msg.sender
        );

        // Grant MINTER_BURNER_ROLE to manager contract on pool token
        bytes32 minterBurnerRole = poolToken.MINTER_BURNER_ROLE();
        poolToken.grantRole(minterBurnerRole, address(manager));

        vm.stopBroadcast();

        // Output addresses
        console.log("MockUSDT deployed at:", address(usdt));
        console.log("InvestmentPoolToken deployed at:", address(poolToken));
        console.log("InvestmentPoolManager deployed at:", address(manager));
    }
} 