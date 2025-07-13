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
    address user2 = address(0x5678);
    address admin = address(this);
    address multisig = address(0xABCD);
    address manager_role = address(0x9876);
    
    uint256 constant USDT_DECIMALS = 6;
    uint256 constant POOL_TOKEN_DECIMALS = 6; // Now both have 6 decimals
    uint256 constant THRESHOLD = 1000 * 10**USDT_DECIMALS; // 1000 USDT
    uint256 constant LOCK_PERIOD = 1 days;
    uint256 constant MULTISIG_INITIAL_BALANCE = 10000 * 10**USDT_DECIMALS;

    function setUp() public {
        usdt = new MockUSDT();
        poolToken = new InvestmentPoolToken("Investment Pool Token", "IPT", admin);
        manager = new InvestmentPoolManager(
            address(usdt),
            address(poolToken),
            multisig,
            THRESHOLD,
            LOCK_PERIOD,
            admin
        );
        // Grant MINTER_BURNER_ROLE to manager
        poolToken.grantRole(poolToken.MINTER_BURNER_ROLE(), address(manager));
        // Grant MANAGER_ROLE to manager_role address
        manager.grantRole(manager.MANAGER_ROLE(), manager_role);
        
        // Mint USDT to users
        usdt.mint(user, 10000 * 10**USDT_DECIMALS); // 10,000 USDT
        usdt.mint(user2, 5000 * 10**USDT_DECIMALS); // 5,000 USDT
        usdt.mint(multisig, MULTISIG_INITIAL_BALANCE); // For testing transfers back
        
        // Users approve manager to spend USDT
        vm.prank(user);
        usdt.approve(address(manager), type(uint256).max);
        vm.prank(user2);
        usdt.approve(address(manager), type(uint256).max);
        vm.prank(multisig);
        usdt.approve(address(manager), type(uint256).max);
    }

    function testDecimals() public view {
        // Both tokens now have 6 decimals
        assertEq(usdt.decimals(), 6);
        assertEq(poolToken.decimals(), 6);
    }

    function testDepositMintsPoolToken() public {
        uint256 depositAmount = 500 * 10**USDT_DECIMALS; // 500 USDT
        vm.prank(user);
        manager.deposit(depositAmount);
        
        // User should have received pool tokens (same amount, same decimals)
        assertEq(poolToken.balanceOf(user), depositAmount);
        
        // Pool contract should have USDT
        assertEq(usdt.balanceOf(address(manager)), depositAmount);
        
        // Check deposit info
        (uint256 amount, uint256 lockUntil) = manager.deposits(user);
        assertEq(amount, depositAmount);
        assertEq(lockUntil, block.timestamp + LOCK_PERIOD);
    }

    function testWithdrawBurnsPoolToken() public {
        uint256 depositAmount = 500 * 10**USDT_DECIMALS; // 500 USDT
        
        // Deposit first
        vm.prank(user);
        manager.deposit(depositAmount);
        
        // Fast forward past lock period
        vm.warp(block.timestamp + LOCK_PERIOD + 1);
        
        // Withdraw
        vm.prank(user);
        manager.withdraw(depositAmount);
        
        // User should have no pool tokens
        assertEq(poolToken.balanceOf(user), 0);
        
        // User should have USDT back
        assertEq(usdt.balanceOf(user), 10000 * 10**USDT_DECIMALS);
        
        // Pool contract should have no USDT
        assertEq(usdt.balanceOf(address(manager)), 0);
    }
    
    function testCannotWithdrawDuringLockPeriod() public {
        uint256 depositAmount = 500 * 10**USDT_DECIMALS; // 500 USDT
        
        // Deposit
        vm.prank(user);
        manager.deposit(depositAmount);
        
        // Try to withdraw before lock period ends
        vm.prank(user);
        vm.expectRevert("Funds locked");
        manager.withdraw(depositAmount);
    }
    
    function testThresholdTransfer() public {
        // Deposit more than threshold
        uint256 depositAmount = 1500 * 10**USDT_DECIMALS; // 1500 USDT > 1000 USDT threshold
        
        vm.prank(user);
        manager.deposit(depositAmount);
        
        // Check that funds were transferred to multisig
        assertEq(usdt.balanceOf(multisig), MULTISIG_INITIAL_BALANCE + depositAmount);
        assertEq(usdt.balanceOf(address(manager)), 0);
    }
    
    function testManualTransferToMultisig() public {
        // Deposit below threshold
        uint256 depositAmount = 800 * 10**USDT_DECIMALS; // 800 USDT < 1000 USDT threshold
        
        vm.prank(user);
        manager.deposit(depositAmount);
        
        // Check that no auto transfer happened
        assertEq(usdt.balanceOf(multisig), MULTISIG_INITIAL_BALANCE);
        assertEq(usdt.balanceOf(address(manager)), depositAmount);
        
        // Manual transfer
        uint256 transferAmount = 500 * 10**USDT_DECIMALS; // 500 USDT
        manager.manualTransferToMultisig(transferAmount);
        
        // Check balances after manual transfer
        assertEq(usdt.balanceOf(multisig), MULTISIG_INITIAL_BALANCE + transferAmount);
        assertEq(usdt.balanceOf(address(manager)), depositAmount - transferAmount);
    }
    
    function testPendingWithdrawal() public {
        // Setup: Deposit, transfer most to multisig, then try to withdraw
        uint256 depositAmount = 800 * 10**USDT_DECIMALS; // 800 USDT
        
        // User 1 deposits
        vm.prank(user);
        manager.deposit(depositAmount);
        
        // Admin transfers most to multisig, leaving only 100 USDT
        uint256 transferAmount = 700 * 10**USDT_DECIMALS; // 700 USDT
        manager.manualTransferToMultisig(transferAmount);
        
        // Now contract has only 100 USDT left
        assertEq(usdt.balanceOf(address(manager)), 100 * 10**USDT_DECIMALS);
        
        // Fast forward past lock period
        vm.warp(block.timestamp + LOCK_PERIOD + 1);
        
        // User 1 tries to withdraw 800 USDT but only 100 is available
        vm.prank(user);
        manager.withdraw(depositAmount);
        
        // Check that withdrawal is pending (no USDT transferred to user)
        assertEq(usdt.balanceOf(user), 10000 * 10**USDT_DECIMALS - depositAmount);
        
        // Check pending withdrawals
        uint256[] memory pendingIds = manager.getPendingWithdrawals(user);
        assertEq(pendingIds.length, 1);
        
        // Admin fulfills pending withdrawal
        // First, we need to get funds back from multisig
        vm.prank(multisig);
        usdt.transfer(address(manager), depositAmount);
        
        // Now fulfill the withdrawal
        manager.fulfillPendingWithdrawal(pendingIds[0]);
        
        // Check that user received USDT
        assertEq(usdt.balanceOf(user), 10000 * 10**USDT_DECIMALS);
    }
    
    function testAdminFunctions() public {
        // Test setThreshold
        uint256 newThreshold = 2000 * 10**USDT_DECIMALS; // 2000 USDT
        manager.setThreshold(newThreshold);
        assertEq(manager.threshold(), newThreshold);
        
        // Test setLockPeriod
        uint256 newLockPeriod = 2 days;
        manager.setLockPeriod(newLockPeriod);
        assertEq(manager.lockPeriod(), newLockPeriod);
        
        // Test setMultisig
        address newMultisig = address(0xBEEF);
        manager.setMultisig(newMultisig);
        assertEq(manager.multisig(), newMultisig);
        
        // Test setManager
        address newManager = address(0xDEAD);
        manager.setManager(newManager);
        assertTrue(manager.hasRole(manager.MANAGER_ROLE(), newManager));
    }
    
    function testEmergencyWithdraw() public {
        // Send some random ERC20 (we'll use a new pool token instance) to manager
        InvestmentPoolToken testToken = new InvestmentPoolToken("Test Token", "TEST", admin);
        testToken.grantRole(testToken.MINTER_BURNER_ROLE(), admin);
        testToken.mint(admin, 1000 * 10**POOL_TOKEN_DECIMALS); // Use correct decimals
        testToken.transfer(address(manager), 1000 * 10**POOL_TOKEN_DECIMALS);
        
        // Manager role can recover it
        vm.prank(manager_role);
        manager.emergencyWithdrawERC20(address(testToken), manager_role, 1000 * 10**POOL_TOKEN_DECIMALS);
        
        // Check that tokens were recovered
        assertEq(testToken.balanceOf(manager_role), 1000 * 10**POOL_TOKEN_DECIMALS);
    }
    
    function testCannotEmergencyWithdrawFundingToken() public {
        // Try to withdraw funding token (should fail)
        vm.prank(manager_role);
        vm.expectRevert("Cannot withdraw pool funding token");
        manager.emergencyWithdrawERC20(address(usdt), manager_role, 100 * 10**USDT_DECIMALS);
    }
    
    function testMultipleUsers() public {
        // User 1 deposits
        vm.prank(user);
        manager.deposit(500 * 10**USDT_DECIMALS);
        
        // User 2 deposits
        vm.prank(user2);
        manager.deposit(300 * 10**USDT_DECIMALS);
        
        // Check pool token balances (same decimals now)
        assertEq(poolToken.balanceOf(user), 500 * 10**POOL_TOKEN_DECIMALS);
        assertEq(poolToken.balanceOf(user2), 300 * 10**POOL_TOKEN_DECIMALS);
        
        // Check user portions
        uint256 user1Portion = manager.userPortion(user);
        uint256 user2Portion = manager.userPortion(user2);
        assertEq(user1Portion, 625 * 10**15); // 0.625 * 10^18 (62.5%)
        assertEq(user2Portion, 375 * 10**15); // 0.375 * 10^18 (37.5%)
    }
    
    // Fuzz testing for deposits
    function testFuzz_Deposit(uint256 amount) public {
        // Bound the amount to reasonable values (1 to 100K USDT)
        amount = bound(amount, 1, 100_000 * 10**USDT_DECIMALS);
        
        // Mint enough USDT to user
        usdt.mint(user, amount);
        
        // Deposit
        vm.prank(user);
        manager.deposit(amount);
        
        // Check balances (same decimals now)
        assertEq(poolToken.balanceOf(user), amount);
        
        // Check if threshold transfer happened
        if (amount >= THRESHOLD) {
            assertEq(usdt.balanceOf(address(manager)), 0);
            assertEq(usdt.balanceOf(multisig), MULTISIG_INITIAL_BALANCE + amount);
        } else {
            assertEq(usdt.balanceOf(address(manager)), amount);
            assertEq(usdt.balanceOf(multisig), MULTISIG_INITIAL_BALANCE);
        }
    }
    
    // Fuzz testing for withdrawals
    function testFuzz_DepositWithdraw(uint256 amount) public {
        // Bound the amount to reasonable values (1 to 100K USDT)
        amount = bound(amount, 1, 100_000 * 10**USDT_DECIMALS);
        
        // Mint enough USDT to user
        usdt.mint(user, amount);
        uint256 initialBalance = usdt.balanceOf(user);
        
        // Deposit
        vm.prank(user);
        manager.deposit(amount);
        
        // Fast forward past lock period
        vm.warp(block.timestamp + LOCK_PERIOD + 1);
        
        // Handle threshold transfers if needed
        if (amount >= THRESHOLD) {
            // Transfer funds back from multisig for withdrawal
            vm.prank(multisig);
            usdt.transfer(address(manager), amount);
        }
        
        // Withdraw
        vm.prank(user);
        manager.withdraw(amount);
        
        // Check if withdrawal was successful or pending
        uint256[] memory pendingIds = manager.getPendingWithdrawals(user);
        
        if (pendingIds.length == 0) {
            // Withdrawal was successful
            assertEq(usdt.balanceOf(user), initialBalance);
        } else {
            // Withdrawal is pending
            assertEq(usdt.balanceOf(user), initialBalance - amount);
            
            // Fulfill the pending withdrawal
            vm.prank(multisig);
            usdt.transfer(address(manager), amount);
            manager.fulfillPendingWithdrawal(pendingIds[0]);
            
            // Now user should have their funds back
            assertEq(usdt.balanceOf(user), initialBalance);
        }
    }
    
    // Edge case: Zero deposit
    function testZeroDeposit() public {
        vm.prank(user);
        vm.expectRevert("Amount=0");
        manager.deposit(0);
    }
    
    // Edge case: Zero withdraw
    function testZeroWithdraw() public {
        vm.prank(user);
        vm.expectRevert("Amount=0");
        manager.withdraw(0);
    }
    
    // Edge case: Withdraw more than deposited
    function testWithdrawMoreThanDeposited() public {
        uint256 depositAmount = 500 * 10**USDT_DECIMALS;
        
        vm.prank(user);
        manager.deposit(depositAmount);
        
        vm.warp(block.timestamp + LOCK_PERIOD + 1);
        
        vm.prank(user);
        vm.expectRevert("Not enough deposited");
        manager.withdraw(depositAmount + 1);
    }
    
    // Edge case: Multiple deposits and withdrawals
    function testMultipleDepositsAndWithdrawals() public {
        // First deposit
        vm.prank(user);
        manager.deposit(300 * 10**USDT_DECIMALS);
        
        // Second deposit
        vm.prank(user);
        manager.deposit(200 * 10**USDT_DECIMALS);
        
        // Fast forward past lock period
        vm.warp(block.timestamp + LOCK_PERIOD + 1);
        
        // First withdrawal
        vm.prank(user);
        manager.withdraw(100 * 10**USDT_DECIMALS);
        
        // Check balances (same decimals now)
        assertEq(poolToken.balanceOf(user), 400 * 10**POOL_TOKEN_DECIMALS);
        
        // Second withdrawal
        vm.prank(user);
        manager.withdraw(400 * 10**USDT_DECIMALS);
        
        // Check balances
        assertEq(poolToken.balanceOf(user), 0);
        assertEq(usdt.balanceOf(user), 10000 * 10**USDT_DECIMALS);
    }
} 