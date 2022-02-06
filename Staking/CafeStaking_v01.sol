// SPDX-License-Identifier: MIT
pragma solidity ^0.8.9;

import "EnumerableSet.sol";
import "Address.sol";
import "Context.sol";
import "ERC165.sol";
import "SafeMath.sol";
import "Ownable.sol";
import "IERC20.sol";

struct StakingEntity {        
    uint256 lastClaimTime;
    uint256 amount;
    uint256 unclaimedTimeInPeriod;
    uint256 claimedTotal;
}
contract CafeStaking_v01 is Context, Ownable {

    using SafeMath for uint256;
    using EnumerableSet for EnumerableSet.UintSet;

    mapping(address => StakingEntity) private _stakeMap;

    IERC20 private _tokenInterface;
    address private _tokenAddress;
    
    uint256 private _stakedBalanceTotal = 0;
    uint256 private _stakedUsersTotal = 0;

    uint256 private _bnbPaid = 0;

    uint256 private _totalClaimedInPeriod = 0;
    uint256 private _totalUnclaimedSecondsInPeriod = 0;

    uint256 private _bnbToPayInPeriod = 0;
    uint256 private _bnbPerMinTokenInPeriodCurrentRate = 0;
    uint256 private _bnbPerMinTokeninPerSecondCurrentRate = 0;

    uint256 private _minStakedTokens = 1 * 10**7;

    uint256 private _timeNextPeriod = 0;
    
    uint256 private _tokenTotalSupplyStakablePercentage = 75;
    uint256 private _tokenTotalSupplyStakable = 0;

    uint256 private immutable _timeFullPeriod = 30;

    bool private _active = false;

    receive() external payable {
        if(_stakingActive()) _update();
        emit Received(msg.sender, msg.value);
    }

    constructor () payable {
        _tokenAddress = 0xdefCafE7eAC90d31BbBA841038DF365DE3c4e207;
        _tokenInterface = IERC20(_tokenAddress);
        _tokenTotalSupplyStakable = (_tokenInterface.totalSupply().div(100)).mul(_tokenTotalSupplyStakablePercentage);
    } 

    event EmergencyWithdrawBNB(address indexed account, uint256 amount);
    event EmergencyWithdrawTokensWithoutClaim(address indexed account, uint256 amount);
    event Stake(address indexed account, uint256 amount);
    event Unstake(address indexed account, uint256 amount);
    event Claim(address indexed account, uint256 amount);
    event UpdateToken(address indexed tokenAddress);
    event SetStakingActive(bool stakingActive);
    event SetTotalSupplyStakablePercentage(uint256 percentage);
    event Received(address, uint);

    function stake(uint256 _amount) external  {
        require(_stakingActive(), "Staking is unavailable at the moment.");
        require(_amount <= _tokenInterface.balanceOf(_msgSender()), "User does not have enough tokens.");         
        require(_amount >= _minStakedTokens, "Amount is below minimum.");
        
        _tokenInterface.transferFrom(_msgSender(), address(this), _amount);
        _claim(_msgSender());

        if(!_userStakeActive(_msgSender())) _stakedUsersTotal = _stakedUsersTotal.add(1);

        uint256 updatedAmount = _stakeMap[_msgSender()].amount.add(_amount);
        _stakeMap[_msgSender()] = StakingEntity({
            lastClaimTime: block.timestamp, 
            unclaimedTimeInPeriod: _timeNextPeriod.sub(block.timestamp),
            claimedTotal: _stakeMap[_msgSender()].claimedTotal,
            amount: updatedAmount
        });

        _stakedBalanceTotal = _stakedBalanceTotal.add(_amount);
        
        
        emit Stake(_msgSender(), _amount);
    }
    function unstake(uint256 _amount) external {
        require(_userStakeActive(_msgSender()), "Nothing to unstake.");
        require(_amount <= _stakeMap[_msgSender()].amount, "Tokens amount requested to unstake is exceeds staked amount.");
        
        _claim(_msgSender());

        _tokenInterface.transfer(_msgSender(), _amount);
        
        uint256 updatedAmount = _stakeMap[_msgSender()].amount.sub(_amount);
        _stakeMap[_msgSender()] = StakingEntity({
            lastClaimTime: block.timestamp, 
            unclaimedTimeInPeriod: _stakeMap[_msgSender()].unclaimedTimeInPeriod,
            claimedTotal: _stakeMap[_msgSender()].claimedTotal,
            amount: updatedAmount
        });
        
        _stakedBalanceTotal = _stakedBalanceTotal.sub(_amount);
        if(!_userStakeActive(_msgSender())) _stakedUsersTotal = _stakedUsersTotal.sub(1);

        emit Unstake(_msgSender(), _amount);
    }
    function _claim(address sender) internal {

        _update();
        uint256 currentPayout = 0;
        if(_userStakeActive(sender)) {
            currentPayout = _calculateCurrentReward(sender);
            
            payable(sender).transfer(currentPayout);

            _stakeMap[sender] = StakingEntity({
                lastClaimTime: block.timestamp, 
                unclaimedTimeInPeriod: _timeNextPeriod.sub(block.timestamp),
                claimedTotal: _stakeMap[sender].claimedTotal.add(currentPayout),
                amount: _stakeMap[sender].amount
            });
            _totalClaimedInPeriod = _totalClaimedInPeriod.add(currentPayout);
            _bnbPaid = _bnbPaid.add(currentPayout);
        }    
        emit Claim(sender, currentPayout);
    }
    function claim() external {
        require(_userStakeActive(_msgSender()), "Nothing is staked.");
        require(_stakeMap[_msgSender()].lastClaimTime.add(1 hours) <= block.timestamp, "Cannot claim more than once in 1 hour.");
        _claim(_msgSender());
    }
    function _update() internal {
        if(block.timestamp >= _timeNextPeriod) {
            _bnbToPayInPeriod = address(this).balance;
            _timeNextPeriod = (block.timestamp).add(_timeFullPeriod * 1 days);
            _totalClaimedInPeriod = 0;
            _bnbPerMinTokenInPeriodCurrentRate = _bnbToPayInPeriod.div((_tokenTotalSupplyStakable).div(10**7));
            _bnbPerMinTokeninPerSecondCurrentRate = _bnbPerMinTokenInPeriodCurrentRate.div(_timeFullPeriod * 24 * 60 * 60);
        }
        if(block.timestamp <= _timeNextPeriod.sub((_timeFullPeriod * 1 days).div(2))) {
            uint256 deltaBNBToAddInPeriod = (address(this).balance).sub(_bnbToPayInPeriod.sub(_totalClaimedInPeriod));
            if(deltaBNBToAddInPeriod > 0) _bnbToPayInPeriod = _bnbToPayInPeriod.add(deltaBNBToAddInPeriod);
            _bnbPerMinTokenInPeriodCurrentRate = _bnbToPayInPeriod.div((_tokenTotalSupplyStakable).div(10**7));
            _bnbPerMinTokeninPerSecondCurrentRate = _bnbPerMinTokenInPeriodCurrentRate.div(_timeFullPeriod * 24 * 60 * 60);
        }
    }
    function _calculateCurrentReward(address sender) private view returns (uint256) {
        return (_stakeMap[sender].amount).div(10**7) * _bnbPerMinTokeninPerSecondCurrentRate * _calculateCorrectedStakedTimeInSeconds(sender);
    }
    function _calculateCorrectedStakedTimeInSeconds(address sender) private view returns (uint256) {
        uint256 currentStakedTimeInSeconds = (block.timestamp.sub(_stakeMap[sender].lastClaimTime));
        uint256 correctedStakedTimeInSeconds = currentStakedTimeInSeconds >= (_timeFullPeriod * 24 * 60 * 60).div(2) ? (_timeFullPeriod * 24 * 60 * 60).div(2) : currentStakedTimeInSeconds;
        if(_stakeMap[sender].lastClaimTime == 0) correctedStakedTimeInSeconds = 0;
        return correctedStakedTimeInSeconds;
    }
    function _userStakeActive(address sender) internal view returns(bool) {
        bool isActive = false;
        if(_stakeMap[sender].amount >= _minStakedTokens) isActive = true;
        return isActive;
    }
    function _stakingActive() internal view returns(bool) {
        return _active;
    }
    function _getScaledValue(uint256 value) internal pure returns(uint256) {
        return value * 10**10;
    }  
    function setStakingActive(bool active) external onlyOwner() {
        _active = active;
        emit SetStakingActive(_active);
    }
    function updateToken(address adr) external onlyOwner() {
        _tokenAddress = adr;
        _tokenInterface = IERC20(_tokenAddress);
        _tokenTotalSupplyStakable = (_tokenInterface.totalSupply().div(100)).mul(_tokenTotalSupplyStakablePercentage);
        emit UpdateToken(adr);
    }
    function setTotalSupplyStakablePercentage(uint256 percentage) external onlyOwner() {
        require(percentage <=100, "Percentage cannot be higher than 100");
        _tokenTotalSupplyStakablePercentage = percentage;
        _tokenTotalSupplyStakable = (_tokenInterface.totalSupply().div(100)).mul(_tokenTotalSupplyStakablePercentage);
        emit SetTotalSupplyStakablePercentage(percentage);
    }
    function emergencyWithdrawBNB() external onlyOwner() {
       uint256 balance = address(this).balance;
       payable(_msgSender()).transfer(balance);
       emit EmergencyWithdrawBNB(_msgSender(), balance);
    }
    function emergencyWithdrawTokensWithoutClaim() external {
        require(_stakeMap[_msgSender()].amount > 0, "Nothing to withdraw.");
        uint256 _amount = _stakeMap[_msgSender()].amount;
        _tokenInterface.transfer(_msgSender(), _amount);
        uint256 updatedAmount = 0;
        if(_userStakeActive(_msgSender())) {
            _stakedBalanceTotal = _stakedBalanceTotal.sub(_amount);
            _stakedUsersTotal = _stakedUsersTotal.sub(1);
        }
        _stakeMap[_msgSender()] = StakingEntity({
            lastClaimTime: block.timestamp, 
            unclaimedTimeInPeriod: _stakeMap[_msgSender()].unclaimedTimeInPeriod,
            claimedTotal: _stakeMap[_msgSender()].claimedTotal,
            amount: updatedAmount
        });  
        emit EmergencyWithdrawTokensWithoutClaim(_msgSender(), _amount);
    }
    function isStakingActive() external view returns (bool) {
        return _stakingActive();
    }
    function getPoolBalance() external view returns (uint256) {
        return address(this).balance;
    }
    function getStakedBalanceTotal() external view returns (uint256) {
        return _stakedBalanceTotal;
    }
    function getStakedUsersTotal() external view returns (uint256) {
        return _stakedUsersTotal;
    }
    function getTotalPaid() external view returns (uint256) {
        return _bnbPaid;
    }
    function getBnbToPayInPeriod() external view returns (uint256) {
        return _bnbToPayInPeriod;
    }
    function getMinTokensForStaking() external view returns (uint256) {
        return _minStakedTokens;
    }
    function getTotalPaidInPeriod() external view returns (uint256) {
        return _totalClaimedInPeriod;
    }
    function getCurrentPerTokenBNBRewardRate() external view returns (uint256){
        return _bnbPerMinTokeninPerSecondCurrentRate;
    }
    function getCurrentRewardCalculation(address sender) external view returns (uint256) {
        return _calculateCurrentReward(sender);
    }
    function getCorrectedStakedTimeInSeconds(address sender) external view returns (uint256) {
        return _calculateCorrectedStakedTimeInSeconds(sender);
    }
    function getUnclaimedTimeInSeconds(address sender) external view returns (uint256) {
        return _stakeMap[sender].unclaimedTimeInPeriod;
    }
    function getLastClaimTime(address sender) external view returns (uint256) {
        return _stakeMap[sender].lastClaimTime;
    }
    function getStakedAmount(address sender) external view returns (uint256) {
        return _stakeMap[sender].amount;
    }
    function getUserClaimedTotal(address sender) external view returns (uint256) {
        return _stakeMap[sender].claimedTotal;
    }
    function getTimeFullPeriod() external pure returns (uint256) {
        return _timeFullPeriod;
    }
    function getTimeNextPeriod() external view returns(uint256) {
        return _timeNextPeriod;
    }
    function getTotalSupplyStakable() external view returns(uint256) {
        return _tokenTotalSupplyStakable;
    }
}