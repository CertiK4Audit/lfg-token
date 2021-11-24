// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/math/SafeMath.sol";
import "./libs/SafeBEP20.sol";

contract GamersePool is Ownable, ReentrancyGuard {
    using SafeMath for uint256;
    using SafeBEP20 for IBEP20;

    // Whether a limit is set for users
    bool public hasUserLimit;

    // Accrued token per share
    uint256 public accTokenPerShare;

    // The block number when GAMERSE mining ends.
    uint256 public bonusEndBlock;

    // The block number when GAMERSE mining starts.
    uint256 public startBlock;

    // The block number of the last pool update
    uint256 public lastRewardBlock;

    // GAMERSE tokens created per block.
    uint256 public rewardPerBlock;

    // The precision factor
    uint256 public PRECISION_FACTOR;

    // The reward token
    IBEP20 public rewardToken;

    // The staked token
    IBEP20 public stakedToken;

    // The withdrawal interval
    uint256 public withdrawalInterval;

    // Max withdrawal interval: 30 days.
    uint256 public constant MAXIMUM_WITHDRAWAL_INTERVAL = 30 days;

    // Max penalty fee: 50%
    uint256 public constant MAXIMUM_PENALTY_FEE = 5000;

    // Max penalty duration: 14 days
    uint256 public constant MAXIMUM_PENALTY_DURATION = 14 days;

    // Penalty Fee
    uint256 public penaltyFee;

    // The withdraw lock duration
    uint256 public withdrawLock;

    // Penalty Duration
    uint256 public penaltyDuration;

    // Reward Holder address
    address public rewardHolder;

    // custody address
    address public custodyAddress;

    // Info of each user that stakes tokens (stakedToken)
    mapping(address => UserInfo) public userInfo;
    mapping(address => uint128) private visited;

    struct Stake {
        uint256 stakeAmount;
        uint256 timestampSec;
    }

    struct UserInfo {
        uint256 amount; // How many staked tokens the user has provided
        uint256 rewardDebt; // Reward debt
        uint256 nextWithdrawalUntil; // When can the user withdraw again.
        uint256 penaltyUntil; //When can the user withdraw without penalty
        Stake[] stakes; // stakes array for locking funds
    }

    event AdminTokenRecovery(address tokenRecovered, uint256 amount);
    event Deposit(address indexed user, uint256 amount);
    event EmergencyWithdraw(address indexed user, uint256 amount);
    event NewStartAndEndBlocks(uint256 startBlock, uint256 endBlock);
    event NewRewardPerBlock(uint256 rewardPerBlock);
    event RewardsStop(uint256 blockNumber);
    event Withdraw(address indexed user, uint256 amount);
    event NewWithdrawLock(uint256 amount);
    event NewWithdrawalInterval(uint256 interval);
    event NewPenaltyFee(uint256 fee);
    event NewPenaltyDuration(uint256 fee);

    constructor(
        IBEP20 _stakedToken,
        IBEP20 _rewardToken,
        address _rewardHolder,
        uint256 _rewardPerBlock,
        uint256 _startBlock,
        uint256 _bonusEndBlock,
        uint256 _withdrawalInterval,
        uint256 _withdrawLock,
        uint256 _penaltyFee,
        uint256 _penaltyDuration
    ) public {
        require(_withdrawalInterval <= MAXIMUM_WITHDRAWAL_INTERVAL, "Invalid withdrawal interval");
        require(_penaltyFee <= MAXIMUM_PENALTY_FEE, "Invalid penalty fee");
        require(_penaltyDuration <= MAXIMUM_PENALTY_DURATION, "Invalid penalty duration");

        stakedToken = _stakedToken;
        rewardToken = _rewardToken;
        rewardPerBlock = _rewardPerBlock;
        startBlock = _startBlock;
        bonusEndBlock = _bonusEndBlock;
        withdrawalInterval = _withdrawalInterval;
        withdrawLock = _withdrawLock;
        penaltyFee = _penaltyFee;
        penaltyDuration = _penaltyDuration;
        rewardHolder = _rewardHolder;

        uint256 decimalsRewardToken = uint256(rewardToken.decimals());
        require(decimalsRewardToken < 30, "Must be inferior to 30");

        PRECISION_FACTOR = uint256(10**(uint256(30).sub(decimalsRewardToken)));

        // Set the lastRewardBlock as the startBlock
        lastRewardBlock = startBlock;
    }

    /*
     * @notice Deposit staked tokens and collect reward tokens (if any)
     * @param _amount: amount to withdraw (in rewardToken)
     */
    function deposit(uint256 _amount) external nonReentrant {
        UserInfo storage user = userInfo[msg.sender];

        _updatePool();

        if (user.amount != 0) {
            uint256 pending = user.amount.mul(accTokenPerShare).div(PRECISION_FACTOR).sub(
                user.rewardDebt
            );
            if (pending != 0) {
                rewardToken.safeTransferFrom(rewardHolder, address(msg.sender), pending);
                user.nextWithdrawalUntil = block.timestamp.add(withdrawalInterval);
            }
        }

        if (_amount != 0) {
            stakedToken.safeTransferFrom(address(msg.sender), address(this), _amount);
            user.amount = user.amount.add(_amount);
            user.stakes.push(Stake(_amount, block.timestamp.add(withdrawLock)));

            if (user.nextWithdrawalUntil == 0) {
                user.nextWithdrawalUntil = block.timestamp.add(withdrawalInterval);
                user.penaltyUntil = block.timestamp.add(penaltyDuration);
            }
        }

        user.rewardDebt = user.amount.mul(accTokenPerShare).div(PRECISION_FACTOR);

        emit Deposit(msg.sender, _amount);
    }

    /*
     * @notice Withdraw staked tokens and collect reward tokens
     * @param _amount: amount to withdraw (in rewardToken)
     */
    function withdraw(uint256 _amount) external nonReentrant {
        UserInfo storage user = userInfo[msg.sender];
        require(user.amount >= _amount, "Amount to withdraw too high");
        require(user.nextWithdrawalUntil <= block.timestamp, "Withdrawal locked");

        _updatePool();

        uint256 pending = user.amount.mul(accTokenPerShare).div(PRECISION_FACTOR).sub(
            user.rewardDebt
        );

        if (_amount != 0) {
            uint256 unlocked = _checkRedeemable(msg.sender, _amount);

            if (unlocked != 0) {
                user.amount = user.amount.sub(unlocked);
                stakedToken.safeTransfer(address(msg.sender), unlocked);
            }
        }

        if (pending != 0) {
            if (block.timestamp < user.penaltyUntil) {
                uint256 penaltyAmount = pending.mul(penaltyFee).div(10000);
                rewardToken.safeTransferFrom(rewardHolder, custodyAddress, penaltyAmount);
                rewardToken.safeTransferFrom(
                    rewardHolder,
                    address(msg.sender),
                    pending.sub(penaltyAmount)
                );
            } else {
                rewardToken.safeTransferFrom(rewardHolder, address(msg.sender), pending);
            }
            user.nextWithdrawalUntil = block.timestamp.add(withdrawalInterval);
        }

        user.rewardDebt = user.amount.mul(accTokenPerShare).div(PRECISION_FACTOR);

        emit Withdraw(msg.sender, _amount);
    }

    // Get the unlocked amount.
    function redeemableAmount(address _user) external view returns (uint256) {
        uint256 sum;
        if (block.number >= bonusEndBlock) {
            sum = userInfo[_user].amount;
        } else {
            for (
                uint128 i = visited[_user];
                i < userInfo[_user].stakes.length &&
                    userInfo[_user].stakes[i].timestampSec <= block.timestamp;
                i++
            ) {
                sum += userInfo[_user].stakes[i].stakeAmount;
            }
        }
        return sum;
    }

    function _checkRedeemable(address _sender, uint256 _amount) internal returns (uint256) {
        require(
            userInfo[_sender].stakes[0].timestampSec > 0,
            "Your first deposit is not redeemable yet"
        );

        uint256 sum;
        uint256 penaltyAmount;

        if (block.number >= bonusEndBlock) {
            for (uint128 i = visited[_sender]; i < userInfo[_sender].stakes.length; i++) {
                sum += userInfo[_sender].stakes[i].stakeAmount;
                if (sum == _amount) {
                    visited[_sender] = i + 1;
                    break;
                } else if (sum > _amount) {
                    visited[_sender] = i;
                    userInfo[_sender].stakes[i].stakeAmount = sum.sub(_amount);
                    break;
                }
            }
        } else {
            for (uint128 i = visited[_sender]; i < userInfo[_sender].stakes.length; i++) {
                sum += userInfo[_sender].stakes[i].stakeAmount;
                if (sum == _amount) {
                    visited[_sender] = i + 1;

                    if (block.timestamp < userInfo[_sender].stakes[i].timestampSec)
                        penaltyAmount = penaltyAmount.add(userInfo[_sender].stakes[i].stakeAmount);

                    break;
                } else if (sum > _amount) {
                    visited[_sender] = i;
                    if (block.timestamp < userInfo[_sender].stakes[i].timestampSec) {
                        penaltyAmount = penaltyAmount
                            .add(userInfo[_sender].stakes[i].stakeAmount)
                            .sub(sum)
                            .add(_amount);
                    }
                    userInfo[_sender].stakes[i].stakeAmount = sum.sub(_amount);

                    break;
                }

                if (block.timestamp < userInfo[_sender].stakes[i].timestampSec)
                    penaltyAmount = penaltyAmount.add(userInfo[_sender].stakes[i].stakeAmount);
            }
        }

        return penaltyAmount;
    }

    /*
     * @notice Withdraw staked tokens without caring about rewards rewards
     * @dev Needs to be for emergency.
     */
    function emergencyWithdraw() external nonReentrant {
        UserInfo storage user = userInfo[msg.sender];
        require(user.nextWithdrawalUntil <= block.timestamp, "Withdrawal locked");

        uint256 amountToTransfer = user.amount;
        user.amount = 0;
        user.rewardDebt = 0;
        user.nextWithdrawalUntil = 0;
        user.penaltyUntil = 0;

        if (amountToTransfer != 0) {
            stakedToken.safeTransfer(address(msg.sender), amountToTransfer);
        }

        emit EmergencyWithdraw(msg.sender, user.amount);
    }

    /**
     * @notice It allows the admin to recover wrong tokens sent to the contract
     * @param _tokenAddress: the address of the token to withdraw
     * @param _tokenAmount: the number of tokens to withdraw
     * @dev This function is only callable by admin.
     */
    function recoverWrongTokens(address _tokenAddress, uint256 _tokenAmount) external onlyOwner {
        require(_tokenAddress != address(stakedToken), "Cannot be staked token");
        require(_tokenAddress != address(rewardToken), "Cannot be reward token");

        IBEP20(_tokenAddress).safeTransfer(address(msg.sender), _tokenAmount);

        emit AdminTokenRecovery(_tokenAddress, _tokenAmount);
    }

    /*
     * @notice Stop rewards
     * @dev Only callable by owner
     */
    function stopReward() external onlyOwner {
        bonusEndBlock = block.number;
        emit RewardsStop(block.number);
    }

    /*
     * @notice Update reward per block
     * @dev Only callable by owner.
     * @param _rewardPerBlock: the reward per block
     */
    function updateRewardPerBlock(uint256 _rewardPerBlock) external onlyOwner {
        require(block.number < startBlock, "Pool has started");
        rewardPerBlock = _rewardPerBlock;
        emit NewRewardPerBlock(_rewardPerBlock);
    }

    /**
     * @notice It allows the admin to update start and end blocks
     * @dev This function is only callable by owner.
     * @param _startBlock: the new start block
     * @param _bonusEndBlock: the new end block
     */
    function updateStartAndEndBlocks(uint256 _startBlock, uint256 _bonusEndBlock)
        external
        onlyOwner
    {
        require(startBlock < _startBlock, "New startBlock must be bigger than previous one");
        require(_startBlock < _bonusEndBlock, "New startBlock must be lower than new endBlock");
        require(block.number < _startBlock, "New startBlock must be higher than current block");

        startBlock = _startBlock;
        bonusEndBlock = _bonusEndBlock;

        // Set the lastRewardBlock as the startBlock
        lastRewardBlock = startBlock;

        emit NewStartAndEndBlocks(_startBlock, _bonusEndBlock);
    }

    /*
     * @notice Update the withdrawal interval
     * @dev Only callable by owner.
     * @param _interval: the withdrawal interval for staked token in seconds
     */
    function updateWithdrawalInterval(uint256 _interval) external onlyOwner {
        require(_interval <= MAXIMUM_WITHDRAWAL_INTERVAL, "Invalid withdrawal interval");
        withdrawalInterval = _interval;
        emit NewWithdrawalInterval(_interval);
    }

    /*
     * @notice Update the penalty fee
     * @dev Only callable by owner.
     * @param _fee: the penalty fee
     */
    function updatePenaltyFee(uint256 _fee) external onlyOwner {
        require(_fee <= MAXIMUM_PENALTY_FEE, "Invalid penalty fee");
        penaltyFee = _fee;
        emit NewPenaltyFee(_fee);
    }

    /*
     * @notice Update the withdraw lock value
     * @dev Only callable by owner.
     * @param _withdrawLock: the withdrawLock value
     */
    function updateWithdrawLock(uint256 _withdrawLock) external onlyOwner {
        withdrawLock = _withdrawLock;
        emit NewWithdrawLock(withdrawLock);
    }

    /*
     * @notice Update the penalty duration
     * @dev Only callable by owner.
     * @param _duration: the penalty duration in seconds
     */
    function updatePenaltyDuration(uint256 _duration) external onlyOwner {
        require(_duration <= MAXIMUM_PENALTY_DURATION, "Invalid penalty duration");
        penaltyDuration = _duration;
        emit NewPenaltyDuration(_duration);
    }

    /*
     * @notice Update the custody address
     * @dev Only callable by owner.
     * @param _account: custody address
     */
    function updateCustodyAddress(address _account) external onlyOwner {
        require(_account != address(0), "Invalid address");
        custodyAddress = _account;
    }

    /*
     * @notice View function to see pending reward on frontend.
     * @param _user: user address
     * @return Pending reward for a given user
     */
    function pendingReward(address _user) external view returns (uint256) {
        UserInfo storage user = userInfo[_user];
        uint256 stakedTokenSupply = stakedToken.balanceOf(address(this));
        if (block.number > lastRewardBlock && stakedTokenSupply != 0) {
            uint256 multiplier = _getMultiplier(lastRewardBlock, block.number);
            uint256 cakeReward = multiplier.mul(rewardPerBlock);
            uint256 adjustedTokenPerShare = accTokenPerShare.add(
                cakeReward.mul(PRECISION_FACTOR).div(stakedTokenSupply)
            );
            return
                user.amount.mul(adjustedTokenPerShare).div(PRECISION_FACTOR).sub(user.rewardDebt);
        } else {
            return user.amount.mul(accTokenPerShare).div(PRECISION_FACTOR).sub(user.rewardDebt);
        }
    }

    // View function to see if user can withdraw staked token.
    function canWithdraw(address _user) external view returns (bool) {
        UserInfo storage user = userInfo[_user];
        return block.timestamp >= user.nextWithdrawalUntil;
    }

    /*
     * @notice Update reward variables of the given pool to be up-to-date.
     */
    function _updatePool() internal {
        if (block.number <= lastRewardBlock) {
            return;
        }

        uint256 stakedTokenSupply = stakedToken.balanceOf(address(this));

        if (stakedTokenSupply == 0) {
            lastRewardBlock = block.number;
            return;
        }

        uint256 multiplier = _getMultiplier(lastRewardBlock, block.number);
        uint256 cakeReward = multiplier.mul(rewardPerBlock);
        accTokenPerShare = accTokenPerShare.add(
            cakeReward.mul(PRECISION_FACTOR).div(stakedTokenSupply)
        );
        lastRewardBlock = block.number;
    }

    /*
     * @notice Return reward multiplier over the given _from to _to block.
     * @param _from: block to start
     * @param _to: block to finish
     */
    function _getMultiplier(uint256 _from, uint256 _to) internal view returns (uint256) {
        if (_to <= bonusEndBlock) {
            return _to.sub(_from);
        } else if (_from >= bonusEndBlock) {
            return 0;
        } else {
            return bonusEndBlock.sub(_from);
        }
    }
}