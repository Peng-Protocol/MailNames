// SPDX-License-Identifier: BSL 1.1 - Peng Protocol 2025
pragma solidity ^0.8.2;

// File Version: 0.0.1 (05/10/2025)
// Changelog:
// - 0.0.1 (05/10): Initial with owner/setters, Deposit struct/array, index withdraw/swap-pop, paginated views, events

interface IERC20 {
    function decimals() external view returns (uint8);
    function balanceOf(address account) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}

contract MailLocker {
    address public owner;
    IERC20 public mailToken;
    address public mailNames;

    struct Deposit {
        uint256 amount; // Normalized (no decimals)
        uint256 unlockTime;
    }
    mapping(address => Deposit[]) private userDeposits;

    event DepositLocked(address indexed user, uint256 indexed index, uint256 amount, uint256 unlockTime);
    event DepositWithdrawn(address indexed user, uint256 indexed index, uint256 amount);

    modifier onlyOwner() {
        require(msg.sender == owner, "Not owner");
        _;
    }

    constructor() {
        owner = msg.sender;
    }
    
        // Ownership event
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    
        // Changelog: 0.0.1 (05/10/2025) - Owner-only transferOwnership: Sets new owner, emits event
    function transferOwnership(address _newOwner) external onlyOwner {
        require(_newOwner != address(0), "Invalid owner");
        address oldOwner = owner;
        owner = _newOwner;
        emit OwnershipTransferred(oldOwner, _newOwner);
    }

    function setMailToken(address _mailToken) external onlyOwner {
        mailToken = IERC20(_mailToken);
    }

    function setMailNames(address _mailNames) external onlyOwner {
        mailNames = _mailNames;
    }

    // Deposit: Pull full from MailNames, push normalized Deposit
    function depositLock(uint256 _normalizedAmount, address _user, uint256 _unlockTime) external {
        require(msg.sender == mailNames, "Only MailNames");
        uint8 decimals = mailToken.decimals();
        uint256 fullAmount = _normalizedAmount * (10 ** decimals);
        require(mailToken.transferFrom(mailNames, address(this), fullAmount), "Transfer failed");
        uint256 index = userDeposits[_user].length;
        userDeposits[_user].push(Deposit(_normalizedAmount, _unlockTime));
        emit DepositLocked(_user, index, _normalizedAmount, _unlockTime);
    }

    // Withdraw specific deposit by index (swap-pop for gas)
    function withdraw(uint256 _index) external {
        Deposit[] storage deposits = userDeposits[msg.sender];
        require(_index < deposits.length, "Invalid index");
        Deposit storage dep = deposits[_index];
        require(block.timestamp >= dep.unlockTime, "Not unlocked");
        uint256 amt = dep.amount;
        // Swap and pop
        deposits[_index] = deposits[deposits.length - 1];
        deposits.pop();
        uint8 decimals = mailToken.decimals();
        require(mailToken.transfer(msg.sender, amt * (10 ** decimals)), "Withdraw failed");
        emit DepositWithdrawn(msg.sender, _index, amt);
    }

    // View: Paginated user deposits
    function getUserDeposits(address _user, uint256 _step, uint256 _maxIterations) external view returns (Deposit[] memory deposits) {
        Deposit[] storage all = userDeposits[_user];
        uint256 len = all.length;
        uint256 end = _step + _maxIterations > len ? len : _step + _maxIterations;
        uint256 count = end > _step ? end - _step : 0;
        deposits = new Deposit[](count);
        for (uint256 i = 0; i < count; i++) {
            deposits[i] = all[_step + i];
        }
    }

    // View: Total locked for user (sum amounts)
    function getTotalLocked(address _user) external view returns (uint256 total) {
        Deposit[] storage deps = userDeposits[_user];
        for (uint256 i = 0; i < deps.length; i++) {
            total += deps[i].amount;
        }
    }
}