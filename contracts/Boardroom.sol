// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";

import "./utils/ContractGuard.sol";
import "./utils/ShareWrapper.sol";
import "./interfaces/IBasisAsset.sol";
import "./interfaces/ITreasury.sol";
import "./interfaces/IPegBoardroom.sol";

// support multi-pegs
contract Boardroom is ShareWrapper, ContractGuard {
    using SafeERC20 for IERC20;
    using Address for address;
    using SafeMath for uint256;

    /* ========== DATA STRUCTURES ========== */

    struct Memberseat {
        uint256 lastSnapshotIndex;
        uint256 rewardEarned;
    }

    struct BoardroomSnapshot {
        uint256 time;
        uint256 rewardReceived;
        uint256 rewardPerShare;
    }

    /* ========== STATE VARIABLES ========== */

    // governance
    address public operator;

    // flags
    bool public initialized = false;

    IERC20 public flare;
    IERC20 public light;
    IERC20 public solar;
    ITreasury public treasury;

    mapping(address => mapping(address => Memberseat)) public members; // pegToken => _member => Memberseat
    mapping(address => uint256) public timers; // start deposit time for each members
    mapping(address => BoardroomSnapshot[]) public boardroomHistory; // pegToken => BoardroomSnapshot history

    uint256 public withdrawLockupEpochs;

    address[] public pegTokens;

    /* =================== Added variables (need to keep orders for proxy to work) =================== */

    /* ========== EVENTS ========== */

    event Initialized(address indexed executor, uint256 at);
    event Staked(address indexed user, uint256 amount);
    event Withdrawn(address indexed user, uint256 amount);
    event RewardPaid(address indexed token, address indexed user, uint256 reward);
    event RewardAdded(address indexed token, address indexed user, uint256 reward);
    event RewardSacrificed(address indexed token, address indexed user, uint256 reward);

    /* ========== Modifiers =============== */

    modifier onlyOperator() {
        require(operator == msg.sender, "Boardroom: caller is not the operator");
        _;
    }

    modifier onlyTreasury() {
        require(address(treasury) == msg.sender || operator == msg.sender, "Boardroom: caller is not the treasury");
        _;
    }

    modifier memberExists() {
        require(balanceOf(msg.sender) > 0, "Boardroom: The member does not exist");
        _;
    }

    modifier updateReward(address _member) {
        uint256 _ptlength = pegTokens.length;
        for (uint256 _pti = 0; _pti < _ptlength; ++_pti) {
            address _token = pegTokens[_pti];
            Memberseat memory seat = members[_token][_member];
            seat.rewardEarned = earned(_token, _member);
            seat.lastSnapshotIndex = latestSnapshotIndex(_token);
            members[_token][_member] = seat;
        }
        _;
    }

    modifier notInitialized() {
        require(!initialized, "Boardroom: already initialized");
        _;
    }

    /* ========== GOVERNANCE ========== */

    function initialize(
        IERC20 _flare,
        IERC20 _light,
        IERC20 _solar,
        ITreasury _treasury,
        address _reserveFund
    ) public notInitialized {
        flare = _flare;
        light = _light;
        share = _solar;
        treasury = _treasury;
        reserveFund = _reserveFund;

        withdrawLockupEpochs = 3; // Lock for 12 epochs (72h) before release withdraw

        initialized = true;
        operator = msg.sender;
        emit Initialized(msg.sender, block.number);
    }

    function setOperator(address _operator) external onlyOperator {
        operator = _operator;
    }

    function setTreasury(ITreasury _treasury) external onlyOperator {
        require(address(_treasury) != address(0), "zero");
        treasury = _treasury;
    }

    function setShare(address _solar) external onlyOperator {
        share = IERC20(_solar);
    }

    function setLockUp(uint256 _withdrawLockupEpochs) external onlyOperator {
        require(_withdrawLockupEpochs <= 42, "_withdrawLockupEpochs: out of range"); // <= 2 week
        withdrawLockupEpochs = _withdrawLockupEpochs;
    }

    function addPegToken(address _token) external onlyOperator {
        require(IERC20(_token).totalSupply() > 0, "Boardroom: invalid token");
        uint256 _ptlength = pegTokens.length;
        for (uint256 _pti = 0; _pti < _ptlength; ++_pti) {
            require(pegTokens[_pti] != _token, "Boardroom: existing token");
        }
        require(boardroomHistory[_token].length == 0, "Boardroom: boardroomHistory exists");
        BoardroomSnapshot memory genesisSnapshot = BoardroomSnapshot({time : block.number, rewardReceived : 0, rewardPerShare : 0});
        boardroomHistory[_token].push(genesisSnapshot);
        pegTokens.push(_token);
    }

    function setReserveFund(address _reserveFund) external onlyOperator {
        _setReserveFund(_reserveFund);
    }

    function setStakeFee(uint256 _stakeFee) external onlyOperator {
        _setStakeFee(_stakeFee);
    }

    function setWithdrawFee(uint256 _withdrawFee) external onlyOperator {
        _setWithdrawFee(_withdrawFee);
    }

    /* ========== VIEW FUNCTIONS ========== */

    // =========== Snapshot getters

    function latestSnapshotIndex(address _token) public view returns (uint256) {
        return boardroomHistory[_token].length.sub(1);
    }

    function getLatestSnapshot(address _token) internal view returns (BoardroomSnapshot memory) {
        return boardroomHistory[_token][latestSnapshotIndex(_token)];
    }

    function getLastSnapshotIndexOf(address token, address member) public view returns (uint256) {
        return members[token][member].lastSnapshotIndex;
    }

    function getLastSnapshotOf(address token, address member) internal view returns (BoardroomSnapshot memory) {
        return boardroomHistory[token][getLastSnapshotIndexOf(token, member)];
    }

    function canClaimReward() public pure returns (bool) {
        return true;
    }

    function canWithdraw(address member) external view returns (bool) {
        return timers[member].add(withdrawLockupEpochs) <= treasury.epoch();
    }

    function epoch() external view returns (uint256) {
        return treasury.epoch();
    }

    function nextEpochPoint() external view returns (uint256) {
        return treasury.nextEpochPoint();
    }

    function getPegTokenPrice(address _token) external view returns (uint256) {
        return treasury.getPegTokenPrice(_token);
    }

    function getPegTokenUpdatedPrice(address _token) external view returns (uint256) {
        return treasury.getPegTokenUpdatedPrice(_token);
    }

    // =========== Member getters

    function rewardPerShare(address _token) public view returns (uint256) {
        return getLatestSnapshot(_token).rewardPerShare;
    }

    function earned(address _token, address _member) public view returns (uint256) {
        uint256 latestRPS = getLatestSnapshot(_token).rewardPerShare;
        uint256 storedRPS = getLastSnapshotOf(_token, _member).rewardPerShare;

        return balanceOf(_member).mul(latestRPS.sub(storedRPS)).div(1e18).add(members[_token][_member].rewardEarned);
    }

    function numOfPegTokens() public view returns (uint256) {
        return pegTokens.length;
    }

    function earnedAllPegTokens(address _member) external view returns (uint256 _numOfPegTokens, address[] memory _pegTokenAddresses, uint256[] memory _earnedPegTokens) {
        _numOfPegTokens = numOfPegTokens();
        _pegTokenAddresses = new address[](_numOfPegTokens);
        _earnedPegTokens = new uint256[](_numOfPegTokens);
        for (uint256 i = 0; i < _numOfPegTokens; i++) {
            _pegTokenAddresses[i] = pegTokens[i];
            _earnedPegTokens[i] = earned(_pegTokenAddresses[i], _member);
        }
    }

    /* ========== MUTATIVE FUNCTIONS ========== */

    function stake(uint256 amount) public override onlyOneBlock updateReward(msg.sender) {
        require(amount > 0, "Boardroom: Cannot stake 0");
        super.stake(amount);
        timers[msg.sender] = treasury.epoch();
        // reset timer
        emit Staked(msg.sender, amount);
    }

    function withdraw(uint256 amount) public override onlyOneBlock memberExists updateReward(msg.sender) {
        require(amount > 0, "Boardroom: Cannot withdraw 0");
        require(timers[msg.sender].add(withdrawLockupEpochs) <= treasury.epoch(), "Boardroom: still in withdraw lockup");
        _sacrificeReward();
        super.withdraw(amount);
        emit Withdrawn(msg.sender, amount);
    }

    function exit() external {
        withdraw(balanceOf(msg.sender));
    }

    function _sacrificeReward() internal updateReward(msg.sender) {
        uint256 _ptlength = pegTokens.length;
        for (uint256 _pti = 0; _pti < _ptlength; ++_pti) {
            address _token = pegTokens[_pti];
            uint256 reward = members[_token][msg.sender].rewardEarned;
            IBasisAsset(_token).burn(reward);
            members[_token][msg.sender].rewardEarned = 0;
            emit RewardSacrificed(_token, msg.sender, reward);
        }
    }

    function claimReward() external onlyOneBlock {
        _claimReward();
    }

    function _claimReward() internal updateReward(msg.sender) {
        timers[msg.sender] = treasury.epoch(); // reset timer
        uint256 _ptlength = pegTokens.length;
        for (uint256 _pti = 0; _pti < _ptlength; ++_pti) {
            address _token = pegTokens[_pti];
            uint256 _reward = members[_token][msg.sender].rewardEarned;
            if (_reward > 0) {
                IERC20(_token).safeTransfer(msg.sender, _reward);
                members[_token][msg.sender].rewardEarned = 0;
                emit RewardPaid(_token, msg.sender, _reward);
            }
        }
    }

    function allocateSeigniorage(address _token, uint256 _amount) external onlyTreasury {
        require(_amount > 0, "Boardroom: Cannot allocate 0");
        IERC20(_token).safeTransferFrom(msg.sender, address(this), _amount);
        uint256 _totalSupply = totalSupply();
        require(_totalSupply > 0, "Boardroom: Cannot allocate when totalSupply is 0");
        require(boardroomHistory[_token].length > 0, "Boardroom: Cannot allocate when boardroomHistory is empty");

        // Create & add new snapshot
        uint256 prevRPS = getLatestSnapshot(_token).rewardPerShare;
        uint256 nextRPS = prevRPS.add(_amount.mul(1e18).div(_totalSupply));

        BoardroomSnapshot memory newSnapshot = BoardroomSnapshot({
            time : block.number,
            rewardReceived : _amount,
            rewardPerShare : nextRPS
            });
        boardroomHistory[_token].push(newSnapshot);

        emit RewardAdded(_token, msg.sender, _amount);
    }

    function governanceRecoverUnsupported(IERC20 _token, uint256 _amount, address _to) external onlyOperator {
        // do not allow to drain core tokens
        require(address(_token) != address(flare), "flare");
        require(address(_token) != address(light), "light");
        require(address(_token) != address(share), "solar");
        _token.safeTransfer(_to, _amount);
    }
}
