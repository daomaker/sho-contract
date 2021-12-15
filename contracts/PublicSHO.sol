//SPDX-License-Identifier: MIT
pragma solidity =0.8.4;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/security/ReentrancyGuard.sol";
import "hardhat/console.sol";

contract PublicSHO is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    uint32 constant HUNDRED_PERCENT = 1e6;

    struct User {
        uint128 allocation;
        uint32 claimedUnlocksCount;
        uint32 feePercentageCurrentUnlock;
        uint32 feePercentageNextUnlock;

        uint128 totalUnlocked;
        uint128 totalClaimed;
    }

    mapping(address => User) public users;

    IERC20 public immutable shoToken;
    uint64 public immutable startTime;
    uint32 public passedUnlocksCount;
    uint32[] public unlockPercentages;
    uint32[] public unlockPeriods;

    uint128 public globalTotalAllocation;
    address public immutable feeCollector;
    uint32 public immutable initialFeePercentage;
    uint32 public collectedUnlocksCount;
    uint128[] public extraFees;

    event Claim (
        address user,
        uint32 currentUnlock,
        uint32 increasedFeePercentage,
        uint128 receivedTokens,
        uint128 unlockedTokens
    );

    event FeeCollection (
        uint128 totalFee,
        uint128 baseFee,
        uint128 extraFee,
        uint32 currentUnlock
    );

    event Sync (uint32 passedUnlocksCount);

    modifier onlyFeeCollector() {
        require(feeCollector == msg.sender, "PublicSHO: caller is not the fee collector");
        _;
    }

    modifier onlyWhitelisted() {
        require(users[msg.sender].allocation > 0, "PublicSHO: caller is not whitelisted");
        _;
    }

    /**
        @param _shoToken token that whitelisted users claim
        @param _unlockPercentagesDiff array of unlock percentages as differentials
            (how much of total user's whitelisted allocation can a user claim per unlock) 
        @param _unlockPeriodsDiff array of unlock periods as differentials
            (when unlocks happen from startTime)
        @param _initialFeePercentage initial fee in percentage 
        @param _feeCollector EOA that can collect fees
        @param _startTime when users can start claiming
     */
    constructor(
        IERC20 _shoToken,
        uint32[] memory _unlockPercentagesDiff,
        uint32[] memory _unlockPeriodsDiff,
        uint32 _initialFeePercentage,
        address _feeCollector,
        uint64 _startTime
    ) {
        require(address(_shoToken) != address(0), "PublicSHO: sho token zero address");
        require(_unlockPercentagesDiff.length > 0, "PublicSHO: 0 unlock percentages");
        require(_unlockPercentagesDiff.length <= 200, "PublicSHO: too many unlock percentages");
        require(_unlockPeriodsDiff.length == _unlockPercentagesDiff.length, "PublicSHO: different array lengths");
        require(_initialFeePercentage <= HUNDRED_PERCENT, "PublicSHO: initial fee percentage higher than 100%");
        require(_feeCollector != address(0), "PublicSHO: fee collector zero address");
        require(_startTime > block.timestamp, "PublicSHO: start time must be in future");

        // build arrays of sums for easier calculations
        uint32[] memory _unlockPercentages = _buildArraySum(_unlockPercentagesDiff);
        uint32[] memory _unlockPeriods = _buildArraySum(_unlockPeriodsDiff);
        require(_unlockPercentages[_unlockPercentages.length - 1] == HUNDRED_PERCENT, "PublicSHO: invalid unlock percentages");

        shoToken = _shoToken;
        unlockPercentages = _unlockPercentages;
        unlockPeriods = _unlockPeriods;
        initialFeePercentage = _initialFeePercentage;
        feeCollector = _feeCollector;
        startTime = _startTime;
        extraFees = new uint128[](_unlockPercentagesDiff.length);
    }

    /** 
        Whitelisting shall be allowed only until the SHO token is received for security reasons.
        @param wallets addresses to whitelist
        @param allocations users total allocation
    */
    function whitelistUsers(
        address[] calldata wallets,
        uint128[] calldata allocations
    ) external onlyOwner {
        require(shoToken.balanceOf(address(this)) == 0, "PublicSHO: whitelisting too late");
        require(wallets.length != 0, "PublicSHO: zero length array");
        require(wallets.length == allocations.length, "PublicSHO: different array lengths");

        uint128 _globalTotalAllocation;
        for (uint256 i = 0; i < wallets.length; i++) {
            User storage user = users[wallets[i]];
            require(user.allocation == 0, "PublicSHO: some users are already whitelisted");
            user.allocation = allocations[i];
            user.feePercentageCurrentUnlock = initialFeePercentage;
            user.feePercentageNextUnlock = initialFeePercentage;
        
            _globalTotalAllocation += allocations[i];
        }
        globalTotalAllocation = _globalTotalAllocation;
    }

    /**
        It's important that the fees are collectable not depedning on if users are claiming, 
        otherwise the fees could be collected when users claim.
     */ 
    function collectFees() external onlyFeeCollector nonReentrant returns (uint128 baseFee, uint128 extraFee) {
        sync();
        require(collectedUnlocksCount < passedUnlocksCount, "PublicSHO: no fees to collect");
        uint32 currentUnlock = passedUnlocksCount - 1;

        uint32 lastUnlockPercentage = collectedUnlocksCount > 0 ? unlockPercentages[collectedUnlocksCount - 1] : 0;
        uint128 lastExtraFee = collectedUnlocksCount > 0 ? extraFees[collectedUnlocksCount - 1] : 0;

        uint128 globalAllocation = globalTotalAllocation * (unlockPercentages[currentUnlock] - lastUnlockPercentage) / HUNDRED_PERCENT;
        baseFee = globalAllocation * initialFeePercentage / HUNDRED_PERCENT;
        extraFee = extraFees[currentUnlock] - lastExtraFee;
        uint128 totalFee = baseFee + extraFee;

        collectedUnlocksCount = currentUnlock + 1;
        shoToken.safeTransfer(msg.sender, totalFee);
        emit FeeCollection(
            totalFee, 
            baseFee, 
            extraFee, 
            currentUnlock
        );
    }

    /**
        Users can choose how much they want to claim and depending on that (ratio totalClaimed / totalUnlocked), 
        their fee for the next unlocks increases or not.
        @param amountToClaim this amount is limited if it's greater than available amount to claim
     */
    function claim(
        uint128 amountToClaim
    ) external onlyWhitelisted nonReentrant returns (
        uint32 increasedFeePercentage,
        uint128 availableToClaim, 
        uint128 receivedTokens,
        uint128 unlockedTokens
    ) {
        sync();
        User memory user = users[msg.sender];
        require(passedUnlocksCount > 0, "PublicSHO: no unlocks passed");
        require(amountToClaim <= user.allocation, "PublicSHO: passed amount too high");
        uint32 currentUnlock = passedUnlocksCount - 1;

        unlockedTokens = _unlockUserTokens(user);

        availableToClaim = user.totalUnlocked - user.totalClaimed;
        require(availableToClaim > 0, "PublicSHO: no tokens to claim");
        
        receivedTokens = amountToClaim > availableToClaim ? availableToClaim : amountToClaim;
        user.totalClaimed += receivedTokens;
        user.claimedUnlocksCount = currentUnlock + 1;

        increasedFeePercentage = _updateUserFee(user);
        
        users[msg.sender] = user;
        shoToken.safeTransfer(msg.sender, receivedTokens);
        emit Claim(
            msg.sender, 
            currentUnlock, 
            increasedFeePercentage,
            receivedTokens,
            unlockedTokens
        );
    }

    /**  Updates passedUnlocksCount */
    function sync() public {
        require(block.timestamp >= startTime, "PublicSHO: before startTime");

        uint256 timeSinceStart = block.timestamp - startTime;
        uint256 maxReleases = unlockPeriods.length;
        uint32 _passedUnlocksCount = passedUnlocksCount;

        while (_passedUnlocksCount < maxReleases && timeSinceStart >= unlockPeriods[_passedUnlocksCount]) {
            _passedUnlocksCount++;
        }

        if (_passedUnlocksCount > passedUnlocksCount) {
            passedUnlocksCount = _passedUnlocksCount;
            emit Sync(_passedUnlocksCount);
        } 
    }

    function _updateUserFee(User memory user) private returns (uint32 increasedFeePercentage) {
        uint32 currentUnlock = passedUnlocksCount - 1;

        if (currentUnlock < unlockPeriods.length - 1) {
            uint32 claimedRatio = uint32(user.totalClaimed * HUNDRED_PERCENT / user.totalUnlocked);
            if (claimedRatio > user.feePercentageNextUnlock) {
                increasedFeePercentage = claimedRatio - user.feePercentageNextUnlock;
                user.feePercentageNextUnlock = claimedRatio;

                uint128 tokensNextUnlock = user.allocation * (unlockPercentages[currentUnlock + 1] - unlockPercentages[currentUnlock]) / HUNDRED_PERCENT;
                uint128 extraFee = tokensNextUnlock * increasedFeePercentage / HUNDRED_PERCENT; 
                if (extraFees[currentUnlock + 1] == 0 && extraFees[currentUnlock] > 0) {
                    extraFees[currentUnlock + 1] = extraFees[currentUnlock] +
                        unlockPercentages[currentUnlock + 1] * extraFees[currentUnlock] / unlockPercentages[currentUnlock];
                }
                extraFees[currentUnlock + 1] += extraFee;
            }
        }
    }

    function _unlockUserTokens(User memory user) private view returns (uint128 unlockedTokens) {
        uint32 currentUnlock = passedUnlocksCount - 1;

        if (user.claimedUnlocksCount <= currentUnlock) {
            user.feePercentageCurrentUnlock = user.feePercentageNextUnlock;

            uint32 lastUnlockPercentage = user.claimedUnlocksCount > 0 ? unlockPercentages[user.claimedUnlocksCount - 1] : 0;
            unlockedTokens = user.allocation * (unlockPercentages[currentUnlock] - lastUnlockPercentage) / HUNDRED_PERCENT;
            unlockedTokens -= unlockedTokens * user.feePercentageCurrentUnlock / HUNDRED_PERCENT;
            user.totalUnlocked += unlockedTokens;
        }
    }

    function _buildArraySum(uint32[] memory diffArray) internal pure returns (uint32[] memory) {
        uint256 len = diffArray.length;
        uint32[] memory sumArray = new uint32[](len);
        uint32 lastSum = 0;
        for (uint256 i = 0; i < len; i++) {
            if (i > 0) {
                lastSum = sumArray[i - 1];
            }
            sumArray[i] = lastSum + diffArray[i];
        }
        return sumArray;
    }
}