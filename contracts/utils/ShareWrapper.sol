// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/SafeERC20.sol";

contract ShareWrapper {
    using SafeMath for uint256;
    using SafeERC20 for IERC20;

    IERC20 public share;

    address public reserveFund;
    uint256 public withdrawFee;
    uint256 public stakeFee;

    uint256 private _totalSupply;
    mapping(address => uint256) private _balances;

    function totalSupply() public view returns (uint256) {
        return _totalSupply;
    }

    function balanceOf(address account) public view returns (uint256) {
        return _balances[account];
    }

    function _setStakeFee(uint256 _stakeFee) internal  {
        require(_stakeFee <= 5, "Max stake fee is 5%");
        stakeFee = _stakeFee;
    }

    function _setWithdrawFee(uint256 _withdrawFee) internal  {
        require(_withdrawFee <= 20, "Max withdraw fee is 20%");
        withdrawFee = _withdrawFee;
    }

    function _setReserveFund(address _reserveFund) internal {
        require(_reserveFund != address(0), "reserveFund address cannot be 0 address");
        reserveFund = _reserveFund;
    }

    function stake(uint256 amount) public virtual {
        share.safeTransferFrom(msg.sender, address(this), amount);
        if (stakeFee > 0) {
            uint256 feeAmount = amount.mul(stakeFee).div(100);
            share.safeTransfer(reserveFund, feeAmount);
            amount = amount.sub(feeAmount);
        }
        _totalSupply = _totalSupply.add(amount);
        _balances[msg.sender] = _balances[msg.sender].add(amount);
    }

    function withdraw(uint256 amount) public virtual {
        uint256 memberShare = _balances[msg.sender];
        require(memberShare >= amount, "Boardroom: withdraw request greater than staked amount");
        _totalSupply = _totalSupply.sub(amount);
        _balances[msg.sender] = memberShare.sub(amount);
        if (withdrawFee > 0) {
            uint256 feeAmount = amount.mul(withdrawFee).div(100);
            share.safeTransfer(reserveFund, feeAmount);
            amount = amount.sub(feeAmount);
        }
        share.safeTransfer(msg.sender, amount);
    }
}
