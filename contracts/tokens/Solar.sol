// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

import "@openzeppelin/contracts/math/SafeMath.sol";
import "@openzeppelin/contracts/token/ERC20/ERC20Burnable.sol";

import "../owner/Operator.sol";

contract SolarShare is ERC20Burnable, Operator {
    using SafeMath for uint256;

    // TOTAL MAX SUPPLY = 100.000 SOLAR
    uint256 public constant FARMING_POOL_REWARD_ALLOCATION = 50000 ether;
    uint256 public constant DAO_FUND_POOL_ALLOCATION = 37500 ether;
    uint256 public constant DEV_FUND_POOL_ALLOCATION = 12500 ether;

    uint256 public constant VESTING_DURATION = 365 days;
    uint256 public startTime;
    uint256 public endTime;

    uint256 public daoFundRewardRate;
    uint256 public devFundRewardRate;

    address public daoFund;
    address public devFund;

    uint256 public lastClaimedTime;

    bool public rewardPoolDistributed = false;

    constructor(uint256 _startTime, address _daoFund, address _devFund) public ERC20("Solar Share", "SOLAR") {
        _mint(msg.sender, 1 ether); // mint 1 SOLAR for initial pools deployment

        startTime = _startTime;
        endTime = startTime + VESTING_DURATION;

        lastClaimedTime = startTime;

        daoFundRewardRate = DAO_FUND_POOL_ALLOCATION.div(VESTING_DURATION);
        devFundRewardRate = DEV_FUND_POOL_ALLOCATION.div(VESTING_DURATION);

        require(_devFund != address(0), "Address cannot be 0");
        devFund = _devFund;

        require(_daoFund != address(0), "Address cannot be 0");
        daoFund = _daoFund;

    }

    function setDaoFund(address _daoFund) external onlyOperator {
        require(_daoFund != address(0), "zero");
        daoFund = _daoFund;
    }

    function setDevFund(address _devFund) external onlyOperator {
        require(_devFund != address(0), "zero");
        devFund = _devFund;
    }

    function unclaimedDaoFund() public view returns (uint256 _pending) {
        uint256 _now = block.timestamp;
        if (_now > endTime) _now = endTime;
        if (lastClaimedTime >= _now) return 0;
        _pending = _now.sub(lastClaimedTime).mul(daoFundRewardRate);
    }

    function unclaimedDevFund() public view returns (uint256 _pending) {
        uint256 _now = block.timestamp;
        if (_now > endTime) _now = endTime;
        if (lastClaimedTime >= _now) return 0;
        _pending = _now.sub(lastClaimedTime).mul(devFundRewardRate);
    }

    /**
     * @dev Claim pending rewards to community and dev fund
     */
    function claimRewards() external {
        uint256 _pending = unclaimedDaoFund();
        if (_pending > 0 && daoFund != address(0)) {
            _mint(daoFund, _pending);
        }
        _pending = unclaimedDevFund();
        if (_pending > 0 && devFund != address(0)) {
            _mint(devFund, _pending);
        }
        lastClaimedTime = block.timestamp;
    }

    /**
     * @notice distribute to reward pool (only once)
     */
    function distributeReward(address _masterChef) external onlyOperator {
        require(!rewardPoolDistributed, "only can distribute once");
        require(_masterChef != address(0), "!_masterChef");
        rewardPoolDistributed = true;
        _mint(_masterChef, FARMING_POOL_REWARD_ALLOCATION);
    }

    function burn(uint256 amount) public override {
        super.burn(amount);
    }

    function governanceRecoverUnsupported(
        IERC20 _token,
        uint256 _amount,
        address _to
    ) external onlyOperator {
        _token.transfer(_to, _amount);
    }
}
