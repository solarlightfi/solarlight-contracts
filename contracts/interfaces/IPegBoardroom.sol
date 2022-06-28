// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

interface IPegBoardroom {
    function earned(address _token, address _member) external view returns (uint256);

    function updateReward(address _token, address _member) external;

    function claimReward(address _token, address _member) external;

    function sacrificeReward(address _token, address _member) external;

    function allocateSeignioragePegToken(address _token, uint256 _amount) external;
}
