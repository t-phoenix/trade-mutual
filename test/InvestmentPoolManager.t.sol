// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import "forge-std/Test.sol";
import {MockUSDT} from "../src/MockUSDT.sol";
import {InvestmentPoolToken} from "../src/InvestmentPoolToken.sol";
import {InvestmentPoolManager} from "../src/InvestmentPoolManager.sol";

contract InvestmentPoolManagerTest is Test {
    MockUSDT usdt;
    InvestmentPoolToken poolToken;
    InvestmentPoolManager manager;
    address user = address(0x1234);
    address admin = address(this);

    function setUp() public {
        usdt = new MockUSDT();
        poolToken = new InvestmentPoolToken("Investment Pool Token", "IPT", admin);
        manager = new InvestmentPoolManager(
            address(usdt),
            address(poolToken),
            admin, // multisig
            1000e18, // threshold
            1 days, // lockPeriod
            admin
        );
        // Grant MINTER_BURNER_ROLE to manager
        poolToken.grantRole(poolToken.MINTER_BURNER_ROLE(), address(manager));
        // Mint USDT to user
        usdt.mint(user, 10000e18);
        // User approves manager to spend USDT
        vm.prank(user);
        usdt.approve(address(manager), type(uint256).max);
    }

    function testDepositMintsPoolToken() public {
        uint256 depositAmount = 500e18;
        vm.prank(user);
        manager.deposit(depositAmount);
        // User should have received pool tokens
        assertEq(poolToken.balanceOf(user), depositAmount);
        // Pool contract should have USDT
        assertEq(usdt.balanceOf(address(manager)), depositAmount);
    }

    function testWithdrawBurnsPoolToken() public {
        uint256 withdrawAmount = 500e18;
        // Deposit first
        vm.prank(user);
        manager.deposit(withdrawAmount);
        // Fast forward past lock period
        vm.warp(block.timestamp + 2 days);
        // Withdraw
        vm.prank(user);
        manager.withdraw(withdrawAmount);
        // User should have no pool tokens
        assertEq(poolToken.balanceOf(user), 0);
        // User should have USDT back
        assertEq(usdt.balanceOf(user), 10000e18);
        // Pool contract should have no USDT
        assertEq(usdt.balanceOf(address(manager)), 0);
    }
} 