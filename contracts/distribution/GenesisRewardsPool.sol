pragma solidity 0.6.12;
import "@openzeppelin/contracts/math/Math.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";

import "../interfaces/IMultiRewardPool.sol";

// Note that this pool has no minter key.
contract GenesisRewardsPool is IMultiRewardPool, ReentrancyGuard {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    // governance
    address public operator;

    // Info of each user.
    struct UserInfo {
        uint256 amount; // How many LP tokens the user has provided.
        uint256 rewardDebt; // Reward debt. See explanation below.
        uint256 lastDepositTime;
    }

    // Info of each pool.
    struct PoolInfo {
        IERC20 token; // Address of LP token contract.
        uint256 allocPoint; // How many allocation points assigned to this pool. LIGHTs to distribute in the pool.
        uint256 lastRewardTime; // Last time that LIGHTs distribution occurred.
        uint256 _accRewardPerShare; // Accumulated LIGHTs per share, times 1e18. See below.
        bool isStarted; // if lastRewardTime has passed
        uint256 lockedTime;
    }

    IERC20 public light;
    IERC20 public flare;

    // Info of each pool.
    PoolInfo[] public poolInfo;

    // Info of each user that stakes LP tokens.
    mapping(uint256 => mapping(address => UserInfo)) public userInfo;

    // Total allocation points. Must be the sum of all allocation points in all pools.
    uint256 private _totalAllocPoint;

    // The time when light mining starts.
    uint256 public poolStartTime;

    uint256[] public epochTotalRewards = [100000 ether, 75000 ether, 50000 ether, 25000 ether];

    // Time when each epoch ends.
    uint256[4] public epochEndTimes;

    // Reward per second for each of 4 weeks (last item is equal to 0 - for sanity).
    uint256[5] public epochRewardPerSeconds;

    uint256 private constant REWARD_RATE_DENOMINATION = 100;
    uint256 public constant REWARD_RATE_LIGHT = 800;

    event Deposit(address indexed user, uint256 indexed pid, uint256 amount);
    event Withdraw(address indexed user, uint256 indexed pid, uint256 amount);
    event EmergencyWithdraw(
        address indexed user,
        uint256 indexed pid,
        uint256 amount
    );
    event RewardPaid(
        address indexed user,
        uint256 flareAmt,
        uint256 lightAmt
    );

    constructor(
        address _flare,
        address _light,
        uint256 _poolStartTime
    ) public {
        require(block.timestamp < _poolStartTime, "late");

        flare = IERC20(_flare);
        light = IERC20(_light);

        poolStartTime = _poolStartTime;

        epochEndTimes[0] = poolStartTime + 7 days; // 1st week
        epochEndTimes[1] = epochEndTimes[0] + 7 days; // 2nd week
        epochEndTimes[2] = epochEndTimes[1] + 7 days; // 3rd week
        epochEndTimes[3] = epochEndTimes[2] + 7 days; // 4th week

        epochRewardPerSeconds[0] = epochTotalRewards[0].div(7 days);
        epochRewardPerSeconds[1] = epochTotalRewards[1].div(7 days);
        epochRewardPerSeconds[2] = epochTotalRewards[2].div(7 days);
        epochRewardPerSeconds[3] = epochTotalRewards[3].div(7 days);

        epochRewardPerSeconds[4] = 0;
        operator = msg.sender;
    }

    modifier onlyOperator() {
        require(
            operator == msg.sender,
            "GenesisRewardPool: caller is not the operator"
        );
        _;
    }

    function reward() external view override returns (address) {
        return address(flare);
    }

    function multiRewardLength() external view override returns (uint256) {
        return 2;
    }

    function multiRewards()
    external
    view
    override
    returns (address[] memory _rewards)
    {
        _rewards = new address[](2);
        _rewards[0] = address(flare);
        _rewards[1] = address(light);
    }

    function totalAllocPoint() external view override returns (uint256) {
        return _totalAllocPoint;
    }

    function poolLength() external view override returns (uint256) {
        return poolInfo.length;
    }

    function getPoolInfo(uint256 _pid)
    external
    view
    override
    returns (address _lp, uint256 _allocPoint)
    {
        PoolInfo memory pool = poolInfo[_pid];
        _lp = address(pool.token);
        _allocPoint = pool.allocPoint;
    }

    function getRewardPerSecond() external view override returns (uint256) {
        for (uint8 epochId = 0; epochId <= 3; ++epochId) {
            if (block.timestamp <= epochEndTimes[epochId])
                return epochRewardPerSeconds[epochId];
        }
        return 0;
    }

    function getMultiRewardPerSecond()
    external
    view
    override
    returns (uint256[] memory _rewardPerSecondArr)
    {
        _rewardPerSecondArr = new uint256[](2);
        for (uint8 epochId = 0; epochId <= 3; ++epochId) {
            if (block.timestamp <= epochEndTimes[epochId]) {
                _rewardPerSecondArr[0] = epochRewardPerSeconds[epochId];
                _rewardPerSecondArr[1] = _rewardPerSecondArr[0]
                .mul(REWARD_RATE_LIGHT)
                .div(REWARD_RATE_DENOMINATION);
                return _rewardPerSecondArr;
            }
        }
    }

    function checkPoolDuplicate(IERC20 _token) internal view {
        uint256 length = poolInfo.length;
        for (uint256 pid = 0; pid < length; ++pid) {
            require(
                poolInfo[pid].token != _token,
                "rewardPool: existing pool?"
            );
        }
    }

    // Add a new token to the pool. Can only be called by the owner.
    function add(
        uint256 _allocPoint,
        IERC20 _token,
        uint256 _lastRewardTime,
        uint256 _lockedTime
    ) public onlyOperator {
        checkPoolDuplicate(_token);
        massUpdatePools();
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
        bool _isStarted = (_lastRewardTime <= poolStartTime) ||
        (_lastRewardTime <= block.timestamp);
        poolInfo.push(
            PoolInfo({
        token: _token,
        allocPoint: _allocPoint,
        lastRewardTime: _lastRewardTime,
        _accRewardPerShare: 0,
        lockedTime: _lockedTime,
        isStarted: _isStarted
        })
        );
        if (_isStarted) {
            _totalAllocPoint = _totalAllocPoint.add(_allocPoint);
        }
    }

    // Update the given pool's light allocation point. Can only be called by the owner.
    function setPoolAllocation(uint256 _pid, uint256 _allocPoint)
    public
    onlyOperator
    {
        massUpdatePools();
        PoolInfo storage pool = poolInfo[_pid];
        if (pool.isStarted) {
            _totalAllocPoint = _totalAllocPoint.sub(pool.allocPoint).add(
                _allocPoint
            );
        }
        pool.allocPoint = _allocPoint;
    }

    // Update the given pool's light locked time. Can only be called by the owner.
    function setPoolLockedTime(uint256 _pid, uint256 _lockedTime)
    public
    onlyOperator
    {
        massUpdatePools();
        PoolInfo storage pool = poolInfo[_pid];
        pool.lockedTime = _lockedTime;
    }

    // Return accumulate rewards over the given _fromTime to _toTime.
    function getGeneratedReward(uint256 _fromTime, uint256 _toTime)
    public
    view
    returns (uint256)
    {
        for (uint8 epochId = 4; epochId >= 1; --epochId) {
            if (_toTime >= epochEndTimes[epochId - 1]) {
                if (_fromTime >= epochEndTimes[epochId - 1]) {
                    return
                    _toTime.sub(_fromTime).mul(
                        epochRewardPerSeconds[epochId]
                    );
                }
                uint256 _generatedReward = _toTime
                .sub(epochEndTimes[epochId - 1])
                .mul(epochRewardPerSeconds[epochId]);
                if (epochId == 1) {
                    return
                    _generatedReward.add(
                        epochEndTimes[0].sub(_fromTime).mul(
                            epochRewardPerSeconds[0]
                        )
                    );
                }
                for (epochId = epochId - 1; epochId >= 1; --epochId) {
                    if (_fromTime >= epochEndTimes[epochId - 1]) {
                        return
                        _generatedReward.add(
                            epochEndTimes[epochId].sub(_fromTime).mul(
                                epochRewardPerSeconds[epochId]
                            )
                        );
                    }
                    _generatedReward = _generatedReward.add(
                        epochEndTimes[epochId]
                        .sub(epochEndTimes[epochId - 1])
                        .mul(epochRewardPerSeconds[epochId])
                    );
                }
                return
                _generatedReward.add(
                    epochEndTimes[0].sub(_fromTime).mul(
                        epochRewardPerSeconds[0]
                    )
                );
            }
        }
        return _toTime.sub(_fromTime).mul(epochRewardPerSeconds[0]);
    }

    // View function to see pending LIGHTs on frontend.
    function pendingReward(uint256 _pid, address _user)
    public
    view
    override
    returns (uint256)
    {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_user];
        uint256 _accRewardPerShare = pool._accRewardPerShare;
        uint256 tokenSupply = pool.token.balanceOf(address(this));
        if (block.timestamp > pool.lastRewardTime && tokenSupply != 0) {
            uint256 _generatedReward = getGeneratedReward(
                pool.lastRewardTime,
                block.timestamp
            );
            uint256 _flareReward = _generatedReward.mul(pool.allocPoint).div(
                _totalAllocPoint
            );
            _accRewardPerShare = _accRewardPerShare.add(
                _flareReward.mul(1e18).div(tokenSupply)
            );
        }
        return user.amount.mul(_accRewardPerShare).div(1e18).sub(user.rewardDebt);
    }

    function pendingMultiRewards(uint256 _pid, address _user)
    public
    view
    override
    returns (uint256[] memory _pendingMultiRewardArr)
    {
        uint256 _flareReward = pendingReward(_pid, _user);
        _pendingMultiRewardArr = new uint256[](2);
        _pendingMultiRewardArr[0] = _flareReward;
        _pendingMultiRewardArr[1] = _flareReward.mul(REWARD_RATE_LIGHT).div(
            REWARD_RATE_DENOMINATION
        );
    }

    function pendingAllRewards(address _user)
    public
    view
    override
    returns (uint256 _total)
    {
        uint256 length = poolInfo.length;
        for (uint256 pid = 0; pid < length; ++pid) {
            _total = _total.add(pendingReward(pid, _user));
        }
    }

    function pendingAllMultiRewards(address _user)
    external
    view
    override
    returns (uint256[] memory _totalMultiRewardArr)
    {
        uint256 _flareTotalReward = pendingAllRewards(_user);
        _totalMultiRewardArr = new uint256[](2);
        _totalMultiRewardArr[0] = _flareTotalReward;
        _totalMultiRewardArr[1] = _flareTotalReward.mul(REWARD_RATE_LIGHT).div(
            REWARD_RATE_DENOMINATION
        );
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
            _totalAllocPoint = _totalAllocPoint.add(pool.allocPoint);
        }
        if (_totalAllocPoint > 0) {
            uint256 _generatedReward = getGeneratedReward(
                pool.lastRewardTime,
                block.timestamp
            );
            uint256 _flareReward = _generatedReward.mul(pool.allocPoint).div(
                _totalAllocPoint
            );
            pool._accRewardPerShare = pool._accRewardPerShare.add(
                _flareReward.mul(1e18).div(tokenSupply)
            );
        }
        pool.lastRewardTime = block.timestamp;
    }

    function unfrozenStakeTime(uint256 _pid, address _account)
    public
    view
    returns (uint256)
    {
        return
        Math.min(
            userInfo[_pid][_account].lastDepositTime +
            poolInfo[_pid].lockedTime,
            epochEndTimes[3]
        );
    }

    // Deposit LP tokens.
    function deposit(uint256 _pid, uint256 _amount)
    external
    override
    nonReentrant
    {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        updatePool(_pid);
        if (user.amount > 0) {
            uint256 _pending = user
            .amount
            .mul(pool._accRewardPerShare)
            .div(1e18)
            .sub(user.rewardDebt);
            if (_pending > 0) {
                _claimReward(msg.sender, _pending);
            }
        }
        if (_amount > 0) {
            pool.token.safeTransferFrom(msg.sender, address(this), _amount);
            user.amount = user.amount.add(_amount);
        }
        user.rewardDebt = user.amount.mul(pool._accRewardPerShare).div(1e18);
        user.lastDepositTime = block.timestamp;
        emit Deposit(msg.sender, _pid, _amount);
    }

    function withdraw(uint256 _pid, uint256 _amount)
    external
    override
    nonReentrant
    {
        _withdraw(msg.sender, _pid, _amount);
    }

    // Withdraw LP tokens.
    function _withdraw(
        address _account,
        uint256 _pid,
        uint256 _amount
    ) internal {
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_account];
        if (_amount > 0) {
            require(user.amount >= _amount, "withdraw: not good");
            require(
                block.timestamp >= unfrozenStakeTime(_pid, msg.sender),
                "GenesisRewardPool: locked"
            );
        }
        updatePool(_pid);
        uint256 _pending = user.amount.mul(pool._accRewardPerShare).div(1e18).sub(
            user.rewardDebt
        );
        if (_pending > 0) {
            _claimReward(_account, _pending);
        }
        if (_amount > 0) {
            user.amount = user.amount.sub(_amount);
            pool.token.safeTransfer(_account, _amount);
        }
        user.rewardDebt = user.amount.mul(pool._accRewardPerShare).div(1e18);
        emit Withdraw(_account, _pid, _amount);
    }

    function withdrawAll(uint256 _pid) external override nonReentrant {
        _withdraw(msg.sender, _pid, userInfo[_pid][msg.sender].amount);
    }

    function harvestAllRewards() external override nonReentrant {
        uint256 length = poolInfo.length;
        for (uint256 pid = 0; pid < length; ++pid) {
            if (userInfo[pid][msg.sender].amount > 0) {
                _withdraw(msg.sender, pid, 0);
            }
        }
    }

    // Withdraw without caring about rewards. EMERGENCY ONLY.
    function emergencyWithdraw(uint256 _pid) external {
        require(
            block.timestamp >= unfrozenStakeTime(_pid, msg.sender),
            "GenesisRewardPool: locked"
        );
        PoolInfo storage pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][msg.sender];
        uint256 _amount = user.amount;
        user.amount = 0;
        user.rewardDebt = 0;
        pool.token.safeTransfer(msg.sender, _amount);
        emit EmergencyWithdraw(msg.sender, _pid, _amount);
    }

    function _claimReward(address _account, uint256 _flareAmt) internal {
        uint256 _lightAmt = _flareAmt.mul(REWARD_RATE_LIGHT).div(
            REWARD_RATE_DENOMINATION
        );
        _safeTokenTransfer(flare, _account, _flareAmt);
        _safeTokenTransfer(light, _account, _lightAmt);
        emit RewardPaid(_account, _flareAmt, _lightAmt);
    }

    // Safe light transfer function, just in case if rounding error causes pool to not have enough LIGHTs.
    function _safeTokenTransfer(
        IERC20 _token,
        address _to,
        uint256 _amount
    ) internal {
        uint256 _tokenBal = _token.balanceOf(address(this));
        if (_tokenBal > 0) {
            if (_amount > _tokenBal) {
                _token.safeTransfer(_to, _tokenBal);
            } else {
                _token.safeTransfer(_to, _amount);
            }
        }
    }

    function updateRewardRate(uint256) external override {
        revert("Not support");
    }

    function setOperator(address _operator) external onlyOperator {
        operator = _operator;
    }

    function governanceRecoverUnsupported(
        IERC20 _token,
        uint256 amount,
        address to
    ) external onlyOperator {
        if (block.timestamp < epochEndTimes[3] + 90 days) {
            // do not allow to drain token if less than 90 days after farming
            require(
                _token != flare && _token != light,
                "reward"
            );
            uint256 length = poolInfo.length;
            for (uint256 pid = 0; pid < length; ++pid) {
                PoolInfo storage pool = poolInfo[pid];
                require(_token != pool.token, "!pool.token");
            }
        }
        _token.safeTransfer(to, amount);
    }
}