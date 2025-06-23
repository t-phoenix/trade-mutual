// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

import {IERC20} from "../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "../lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {AccessControl} from "../lib/openzeppelin-contracts/contracts/access/AccessControl.sol";
import {InvestmentPoolToken} from "./InvestmentPoolToken.sol";

contract InvestmentPoolManager is AccessControl {
    using SafeERC20 for IERC20;
    using SafeERC20 for InvestmentPoolToken;

    bytes32 public constant MANAGER_ROLE = keccak256("MANAGER_ROLE");

    IERC20 public fundingToken;
    InvestmentPoolToken public poolToken;
    address public multisig;
    uint256 public threshold;
    uint256 public lockPeriod;

    struct DepositInfo {
        uint256 amount;
        uint256 lockUntil;
    }
    mapping(address => DepositInfo) public deposits;
    
    // Track pending withdrawals when contract doesn't have enough balance
    struct PendingWithdrawal {
        address user;
        uint256 amount;
        bool fulfilled;
    }
    PendingWithdrawal[] public pendingWithdrawals;
    mapping(address => uint256[]) public userPendingWithdrawals; // User address -> array of indices in pendingWithdrawals

    event Deposited(address indexed user, uint256 amount, uint256 lockUntil);
    event Withdrawn(address indexed user, uint256 amount);
    event WithdrawalPending(address indexed user, uint256 amount, uint256 pendingWithdrawalId);
    event WithdrawalFulfilled(address indexed user, uint256 amount, uint256 pendingWithdrawalId);
    event ThresholdTransfer(uint256 amount, address indexed to);
    event ManualTransfer(uint256 amount, address indexed to);
    event EmergencyTokenWithdraw(address indexed token, address indexed to, uint256 amount);
    event ConfigUpdated(string key, uint256 value);
    event MultisigUpdated(address indexed newMultisig);
    event ManagerUpdated(address indexed newManager);

    constructor(address _fundingToken, address _poolToken, address _multisig, uint256 _threshold, uint256 _lockPeriod, address admin) {
        require(_fundingToken != address(0) && _poolToken != address(0) && _multisig != address(0), "Zero address");
        fundingToken = IERC20(_fundingToken);
        poolToken = InvestmentPoolToken(_poolToken);
        multisig = _multisig;
        threshold = _threshold;
        lockPeriod = _lockPeriod;
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _grantRole(MANAGER_ROLE, admin);
    }

    // --- Admin Functions ---
    function setThreshold(uint256 _threshold) external onlyRole(DEFAULT_ADMIN_ROLE) {
        threshold = _threshold;
        emit ConfigUpdated("threshold", _threshold);
    }
    function setLockPeriod(uint256 _lockPeriod) external onlyRole(DEFAULT_ADMIN_ROLE) {
        lockPeriod = _lockPeriod;
        emit ConfigUpdated("lockPeriod", _lockPeriod);
    }
    function setMultisig(address _multisig) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_multisig != address(0), "Zero address");
        multisig = _multisig;
        emit MultisigUpdated(_multisig);
    }
    function setManager(address _manager) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_manager != address(0), "Zero address");
        _grantRole(MANAGER_ROLE, _manager);
        emit ManagerUpdated(_manager);
    }
    function setFundingToken(address _fundingToken) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_fundingToken != address(0), "Zero address");
        fundingToken = IERC20(_fundingToken);
    }
    function setPoolToken(address _poolToken) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(_poolToken != address(0), "Zero address");
        poolToken = InvestmentPoolToken(_poolToken);
    }

    // --- Deposit/Withdraw Logic ---
    function deposit(uint256 amount) external {
        require(amount > 0, "Amount=0");
        fundingToken.safeTransferFrom(msg.sender, address(this), amount);
        uint256 lockUntil = block.timestamp + lockPeriod;
        deposits[msg.sender].amount += amount;
        deposits[msg.sender].lockUntil = lockUntil;
        poolToken.mint(msg.sender, amount);
        emit Deposited(msg.sender, amount, lockUntil);
        // Check threshold
        uint256 poolBalanceFundingToken = fundingToken.balanceOf(address(this));
        if (poolBalanceFundingToken >= threshold) {
            _transferToMultisig(poolBalanceFundingToken);
        }
    }

    function withdraw(uint256 amount) external {
        require(amount > 0, "Amount=0");
        DepositInfo storage info = deposits[msg.sender];
        require(info.amount >= amount, "Not enough deposited");
        require(block.timestamp >= info.lockUntil, "Funds locked");
        
        // Update user deposit info and burn pool tokens
        info.amount -= amount;
        poolToken.burn(msg.sender, amount);
        
        // Check if contract has enough balance for withdrawal
        uint256 contractBalance = fundingToken.balanceOf(address(this));
        if (contractBalance >= amount) {
            // If enough balance, process withdrawal immediately
            fundingToken.safeTransfer(msg.sender, amount);
            emit Withdrawn(msg.sender, amount);
        } else {
            // If not enough balance, create pending withdrawal
            uint256 pendingWithdrawalId = pendingWithdrawals.length;
            pendingWithdrawals.push(PendingWithdrawal({
                user: msg.sender,
                amount: amount,
                fulfilled: false
            }));
            userPendingWithdrawals[msg.sender].push(pendingWithdrawalId);
            emit WithdrawalPending(msg.sender, amount, pendingWithdrawalId);
        }
    }
    
    // Admin function to fulfill pending withdrawals
    function fulfillPendingWithdrawal(uint256 pendingWithdrawalId) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(pendingWithdrawalId < pendingWithdrawals.length, "Invalid withdrawal ID");
        PendingWithdrawal storage withdrawal = pendingWithdrawals[pendingWithdrawalId];
        require(!withdrawal.fulfilled, "Already fulfilled");
        
        uint256 contractBalance = fundingToken.balanceOf(address(this));
        require(contractBalance >= withdrawal.amount, "Not enough balance");
        
        withdrawal.fulfilled = true;
        fundingToken.safeTransfer(withdrawal.user, withdrawal.amount);
        emit WithdrawalFulfilled(withdrawal.user, withdrawal.amount, pendingWithdrawalId);
    }
    
    // View function to get pending withdrawals for a user
    function getPendingWithdrawals(address user) external view returns (uint256[] memory) {
        return userPendingWithdrawals[user];
    }

    // --- Pool Info ---
    function poolBalance() public view returns (uint256) {
        return fundingToken.balanceOf(address(this));
    }
    function userPortion(address user) public view returns (uint256) {
        uint256 totalSupply = poolToken.totalSupply();
        if (totalSupply == 0) return 0;
        return (poolToken.balanceOf(user) * 1e18) / totalSupply;
    }

    // --- Threshold/Manual Transfer to Multisig ---
    function manualTransferToMultisig(uint256 amount) external onlyRole(DEFAULT_ADMIN_ROLE) {
        require(amount > 0 && amount <= fundingToken.balanceOf(address(this)), "Invalid amount");
        _transferToMultisig(amount);
        emit ManualTransfer(amount, multisig);
    }
    function _transferToMultisig(uint256 amount) internal {
        fundingToken.safeTransfer(multisig, amount);
        emit ThresholdTransfer(amount, multisig);
    }

    // --- Emergency ERC20 Recovery ---
    function emergencyWithdrawERC20(address token, address to, uint256 amount) external onlyRole(MANAGER_ROLE) {
        require(token != address(fundingToken), "Cannot withdraw pool funding token");
        IERC20(token).safeTransfer(to, amount);
        emit EmergencyTokenWithdraw(token, to, amount);
    }
} 