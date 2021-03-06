pragma solidity 0.6.12;
interface IMultiRewardPool {
    function reward() external view returns (address);

    function multiRewardLength() external view returns (uint256);

    function multiRewards() external view returns (address[] memory);

    function deposit(uint256 _pid, uint256 _amount) external;

    function withdraw(uint256 _pid, uint256 _amount) external;

    function withdrawAll(uint256 _pid) external;

    function harvestAllRewards() external;

    function pendingReward(uint256 _pid, address _user)
    external
    view
    returns (uint256);

    function pendingMultiRewards(uint256 _pid, address _user)
    external
    view
    returns (uint256[] memory);

    function pendingAllRewards(address _user) external view returns (uint256);

    function pendingAllMultiRewards(address _user)
    external
    view
    returns (uint256[] memory);

    function totalAllocPoint() external view returns (uint256);

    function poolLength() external view returns (uint256);

    function getPoolInfo(uint256 _pid)
    external
    view
    returns (address _lp, uint256 _allocPoint);

    function getRewardPerSecond() external view returns (uint256);

    function getMultiRewardPerSecond() external view returns (uint256[] memory);

    function updateRewardRate(uint256 _newRate) external;
}
