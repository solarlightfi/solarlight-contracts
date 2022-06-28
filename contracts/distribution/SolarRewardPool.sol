// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";

// Note that this pool has no minter key of SOLAR (rewards).
// Instead, the governance will call SOLAR distributeReward method and send reward to this pool at the beginning.
contract SolarRewardPool is ReentrancyGuard {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    // governance
    address public operator;

    // vault
    mapping (address => bool) public whitelisted;

    // Info of each user.
    struct UserInfo {
        uint256 amount; // How many LP tokens the user has provided.
        uint256 rewardDebt; // Reward debt. See explanation below.
        uint256 lastDepositTime;
    }

    // Info of each pool.
    struct PoolInfo {
        IERC20 token; // Address of LP token contract.
        uint256 allocPoint; // How many allocation points assigned to this pool. SOLARs to distribute per block.
        uint256 lastRewardTime; // Last timeSolar that SOLARs distribution occurs.
        uint256 accSolarPerShare; // Accumulated SOLARs per share, times 1e18. See below.
        bool isStarted; // if lastRewardTime has passed
        uint256 lockedTime;
    }

    IERC20 public solar;

    // Info of each pool.
    PoolInfo[] public poolInfo;

    // Info of each user that stakes LP tokens.
    mapping(uint256 => mapping(address => UserInfo)) public userInfo;

    // Total allocation points. Must be the sum of all allocation points in all pools.
    uint256 public totalAllocPoint = 0;

    // The time when SOLAR mining starts.
    uint256 public poolStartTime;

    // The time when SOLAR mining ends.
    uint256 public poolEndTime;

    uint256 public rewardPerSecond = 0.00221968543 ether; // 70000 solar / (365 days * 24h * 60min * 60s)
    uint256 public runningTime = 365 days; // 365 days
    uint256 public constant TOTAL_REWARDS = 70000 ether;

    event Deposit(address indexed user, uint256 indexed pid, uint256 amount);
    event Withdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event EmergencyWithdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event RewardPaid(address indexed user, uint256 amount);

    constructor(
        address _solar,
        uint256 _poolStartTime
    ) public {
        require(block.timestamp < _poolStartTime, "late");
        if (_solar != address(0)) solar = IERC20(_solar);
        poolStartTime = _poolStartTime;
        poolEndTime = poolStartTime + runningTime;
        operator = msg.sender;
    }

    modifier onlyOperator() {
        require(operator == msg.sender, "SolarRewardPool: caller is not the operator");
        _;
    }

    function checkPoolDuplicate(IERC20 _token) internal view {
        uint256 length = poolInfo.length;
        for (uint256 pid = 0; pid < length; ++pid) {
            require(poolInfo[pid].token != _token, "SolarRewardPool: existing pool?");
        }
    }

    // Add a new lp to the pool. Can only be called by the owner.
    function add(
        uint256 _allocPoint,
        IERC20 _token,
        bool _withUpdate,
        uint256 _lastRewardTime,
        uint256 _lockedTime
    ) public onlyOperator {
        checkPoolDuplicate(_token);
        if (_withUpdate) {
            massUpdatePools();
        }
        if (block.timestamp < poolStartTime) {
            // chef is sleeping
            if (_lastRewardTime == 0) {
                _lastRewardTime = poolStartTime;
            } else {
                if (_lastRewardTime < poolStartTime) {
                    _lastRewardTime = poolStartTime;
                }
            }
        } else {
            // chef is cooking
            if (_lastRewardTime == 0 || _lastRewardTime < block.timestamp) {
                _lastRewardTime = block.timestamp;
            }
        }
        bool _isStarted =
        (_lastRewardTime <= poolStartTime) ||
        (_lastRewardTime <= block.timestamp);
        poolInfo.push(PoolInfo({
            token : _token,
            allocPoint : _allocPoint,
            lastRewardTime : _lastRewardTime,
            accSolarPerShare : 0,
            lockedTime: _lockedTime,
            isStarted : _isStarted
            }));
        if (_isStarted) {
            totalAllocPoint = totalAllocPoint.add(_allocPoint);
        }
    }

    // Update the given pool's SOLAR allocation point. Can only be called by the owner.
    function set(uint256 _pid, uint256 _allocPoint) public onlyOperator {
        massUpdatePools();
        PoolInfo storage pool = poolInfo[_pid];
        if (pool.isStarted) {
            totalAllocPoint = totalAllocPoint.sub(pool.allocPoint).add(
                _allocPoint
            );
        }
        pool.allocPoint = _allocPoint;
    }

    // Update the given pool's SOLAR allocation point. Can only be called by the owner.
    function setWhitelistedAddress(address _address, bool _status) public onlyOperator {
        whitelisted[_address] = _status;
    }

    // Update the given pool's dst locked time. Can only be called by the owner.
    function setPoolLockedTime(uint256 _pid, uint256 _lockedTime)
    public
    onlyOperator
    {
        massUpdatePools();
        PoolInfo storage pool = poolInfo[_pid];
        pool.lockedTime = _lockedTime;
    }

    function unfrozenStakeTime(uint256 _pid, address _account) public view returns (uint256){
        if (whitelisted[_account]) {
            return 0;
        }
        return userInfo[_pid][_account].lastDepositTime + poolInfo[_pid].lockedTime;
    }

    // Return accumulate rewards over the given _from to _to block.
    function getGeneratedReward(uint256 _fromTime, uint256 _toTime) public view returns (uint256) {
        if (_fromTime >= _toTime) return 0;
        if (_toTime >= poolEndTime) {
            if (_fromTime >= poolEndTime) return 0;
            if (_fromTime <= poolStartTime) return poolEndTime.sub(poolStartTime).mul(rewardPerSecond);
            return poolEndTime.sub(_fromTime).mul(rewardPerSecond);
        } else {
            if (_toTime <= poolStartTime) return 0;
            if (_fromTime <= poolStartTime) return _toTime.sub(poolStartTime).mul(rewardPerSecond);
            return _toTime.sub(_fromTime).mul(rewardPerSecond);
        }
    }

    // View function to see pending SOLARs on frontend.
    function pendingReward(uint256 _pid, address _user) external view returns (uint256) {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_user];
        uint256 accSolarPerShare = pool.accSolarPerShare;
        uint256 tokenSupply = pool.token.balanceOf(address(this));
        if (block.timestamp > pool.lastRewardTime && tokenSupply != 0) {
            uint256 _generatedReward = getGeneratedReward(pool.lastRewardTime, block.timestamp);
            uint256 _solarReward = _generatedReward.mul(pool.allocPoint).div(totalAllocPoint);
            accSolarPerShare = accSolarPerShare.add(_solarReward.mul(1e18).div(tokenSupply));
        }
        return user.amount.mul(accSolarPerShare).div(1e18).sub(user.rewardDebt);
    }

    // Update reward variables for all pools. Be careful of gas spending!
    function massUpdatePools() public {
        uint256 length = poolInfo.length;
        for (uint256 pid = 0; pid < length; ++pid) {
            updatePool(pid);
        }
    }

    // Update reward variables of the given pool to be up-to-date.
    function updatePool(uint256 _pid) public {
        PoolInfo storage pool = poolInfo[_pid];
        if (block.timestamp <= pool.lastRewardTime) {
            return;
        }
        uint256 tokenSupply = pool.token.balanceOf(address(this));
        if (tokenSupply == 0) {
            pool.lastRewardTime = block.timestamp;
            return;
        }
        if (!pool.isStarted) {
            pool.isStarted = true;
            totalAllocPoint = totalAllocPoint.add(pool.allocPoint);
        }
        if (totalAllocPoint > 0) {
            uint256 _generatedReward = getGeneratedReward(pool.lastRewardTime, block.timestamp);
            uint256 _solarReward = _generatedReward.mul(pool.allocPoint).div(totalAllocPoint);
            pool.accSolarPerShare = pool.accSolarPerShare.add(_solarReward.mul(1e18).div(tokenSupply));
        }
        pool.lastRewardTime = block.timestamp;
    }

    // Deposit LP tokens.
    function deposit(uint256 _pid, uint256 _amount) nonReentrant public {
        address _sender = msg.sender;
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_sender];
        updatePool(_pid);
        if (user.amount > 0) {
            uint256 _pending = user.amount.mul(pool.accSolarPerShare).div(1e18).sub(user.rewardDebt);
            if (_pending > 0) {
                safeSolarTransfer(_sender, _pending);
                emit RewardPaid(_sender, _pending);
            }
        }
        if (_amount > 0) {
            pool.token.safeTransferFrom(_sender, address(this), _amount);
            user.amount = user.amount.add(_amount);
        }
        user.lastDepositTime = block.timestamp;
        user.rewardDebt = user.amount.mul(pool.accSolarPerShare).div(1e18);
        emit Deposit(_sender, _pid, _amount);
    }

    // Withdraw LP tokens.
    function withdraw(uint256 _pid, uint256 _amount) nonReentrant public {
        address _sender = msg.sender;
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_sender];
        if (_amount > 0) {
            require(user.amount >= _amount, "withdraw: not good");
            require(block.timestamp >= unfrozenStakeTime(_pid, msg.sender), "SolarRewardPool: locked");
        }
        updatePool(_pid);
        uint256 _pending = user.amount.mul(pool.accSolarPerShare).div(1e18).sub(user.rewardDebt);
        if (_pending > 0) {
            safeSolarTransfer(_sender, _pending);
            emit RewardPaid(_sender, _pending);
        }
        if (_amount > 0) {
            user.amount = user.amount.sub(_amount);
            pool.token.safeTransfer(_sender, _amount);
        }
        user.rewardDebt = user.amount.mul(pool.accSolarPerShare).div(1e18);
        user.lastDepositTime = block.timestamp;
        emit Withdraw(_sender, _pid, _amount);
    }

    function withdrawAll(uint256 _pid) external {
        withdraw(_pid, userInfo[_pid][msg.sender].amount);
    }

    function harvestAllRewards() public {
        uint256 length = poolInfo.length;
        for (uint256 pid = 0; pid < length; ++pid) {
            if (userInfo[pid][msg.sender].amount > 0) {
                deposit(pid, 0);
            }
        }
    }

    // Withdraw without caring about rewards. EMERGENCY ONLY.
    function emergencyWithdraw(uint256 _pid) public {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        require(block.timestamp >= unfrozenStakeTime(_pid, msg.sender), "SolarRewardPool: locked");
        uint256 _amount = user.amount;
        user.amount = 0;
        user.rewardDebt = 0;
        pool.token.safeTransfer(msg.sender, _amount);
        emit EmergencyWithdraw(msg.sender, _pid, _amount);
    }

    // Safe solar transfer function, just in case if rounding error causes pool to not have enough SOLARs.
    function safeSolarTransfer(address _to, uint256 _amount) internal {
        uint256 _solarBal = solar.balanceOf(address(this));
        if (_solarBal > 0) {
            if (_amount > _solarBal) {
                solar.safeTransfer(_to, _solarBal);
            } else {
                solar.safeTransfer(_to, _amount);
            }
        }
    }

    function setOperator(address _operator) external onlyOperator {
        operator = _operator;
    }

    function governanceRecoverUnsupported(IERC20 _token, uint256 amount, address to) external onlyOperator {
        if (block.timestamp < poolEndTime + 90 days) {
            // do not allow to drain core token (SOLAR or lps) if less than 90 days after pool ends
            require(_token != solar, "solar");
            uint256 length = poolInfo.length;
            for (uint256 pid = 0; pid < length; ++pid) {
                PoolInfo storage pool = poolInfo[pid];
                require(_token != pool.token, "pool.token");
            }
        }
        _token.safeTransfer(to, amount);
    }
}
