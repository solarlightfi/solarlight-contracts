// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

import "./IEpoch.sol";

interface ITreasury is IEpoch {
    function getFlarePrice() external view returns (uint256);

    function getFlareUpdatedPrice() external view returns (uint256);

    function getLightPrice() external view returns (uint256);

    function getLightUpdatedPrice() external view returns (uint256);

    function getPegTokenPrice(address _token) external view returns (uint256);

    function getPegTokenUpdatedPrice(address _token) external view returns (uint256);

    function getSupplyLockedBalance(address _token) external view returns (uint256);

    function getNextExpansionRate(address _token) external view returns (uint256);

    function getNextExpansionAmount(address _token) external view returns (uint256);

    function getPegTokenExpansionRate(address) external view returns (uint256);

    function getPegTokenExpansionAmount(address) external view returns (uint256);

    function previousEpochPrice() external view returns (uint256);

    function boardroom() external view returns (address);

    function boardroomSharedPercent() external view returns (uint256);

    function daoFund() external view returns (address);

    function daoFundSharedPercent() external view returns (uint256);

    function devFund() external view returns (address);

    function devFundSharedPercent() external view returns (uint256);

    function getBondDiscountRate(address _token) external view returns (uint256);

    function getBondPremiumRate(address _token) external view returns (uint256);

    function buyBonds(address _token, address _bond, uint256 amount, uint256 targetPrice) external;

    function redeemBonds(address _token, address _bond, uint256 amount, uint256 targetPrice) external;
}
