// SPDX-License-Identifier: MIT

pragma solidity 0.6.12;
pragma experimental ABIEncoderV2;

import "@boringcrypto/boring-solidity/contracts/libraries/BoringMath.sol";
import "@boringcrypto/boring-solidity/contracts/BoringBatchable.sol";
import "@boringcrypto/boring-solidity/contracts/BoringOwnable.sol";
import "./libraries/SignedSafeMath.sol";
import "./interfaces/IRewarder.sol";
import "./interfaces/IMasterJoe.sol";

interface IMigratorJoe {
    // Take the current LP token address and return the new LP token address.
    // Migrator should have full access to the caller's LP token.
    function migrate(IERC20 token) external returns (IERC20);
}

/// @notice The (older) MasterJoe contract gives out a constant number of JOE tokens per block.
/// It is the only address with minting rights for JOE.
/// The idea for this MasterJoe V2 (MCV2) contract is therefore to be the owner of a dummy token
/// that is deposited into the MasterJoe V1 (MCV1) contract.
/// The allocation point for this pool on MCV1 is the total allocation point for all pools that receive double incentives.
contract MasterJoeV2 is BoringOwnable, BoringBatchable {
    using BoringMath for uint256;
    using BoringMath128 for uint128;
    using BoringERC20 for IERC20;
    using SignedSafeMath for int256;

    /// @notice Info of each MCV2 user.
    /// `amount` LP token amount the user has provided.
    /// `rewardDebt` The amount of JOE entitled to the user.
    struct UserInfo {
        uint256 amount;
        int256 rewardDebt;
    }

    /// @notice Info of each MCV2 pool.
    /// `allocPoint` The amount of allocation points assigned to the pool.
    /// Also known as the amount of JOE to distribute per block.
    struct PoolInfo {
        uint128 accJoePerShare;
        uint64 lastRewardBlock;
        uint64 allocPoint;
    }

    /// @notice Address of MCV1 contract.
    IMasterJoe public immutable MASTER_CHEF;
    /// @notice Address of JOE contract.
    IERC20 public immutable JOE;
    /// @notice The index of MCV2 master pool in MCV1.
    uint256 public immutable MASTER_PID;
    // @notice The migrator contract. It has a lot of power. Can only be set through governance (owner).
    IMigratorJoe public migrator;

    /// @notice Info of each MCV2 pool.
    PoolInfo[] public poolInfo;
    /// @notice Address of the LP token for each MCV2 pool.
    IERC20[] public lpToken;
    /// @notice Address of each `IRewarder` contract in MCV2.
    IRewarder[] public rewarder;

    /// @notice Info of each user that stakes LP tokens.
    mapping (uint256 => mapping (address => UserInfo)) public userInfo;
    /// @dev Total allocation points. Must be the sum of all allocation points in all pools.
    uint256 totalAllocPoint;

    uint256 private constant MASTERCHEF_JOE_PER_BLOCK = 1e20;
    uint256 private constant ACC_JOE_PRECISION = 1e12;
    bytes4 private constant SIG_ON_JOE_REWARD = 0xbb6cc2ef; // onJoeReward(uint256,address,uint256)

    event Deposit(address indexed user, uint256 indexed pid, uint256 amount, address indexed to);
    event Withdraw(address indexed user, uint256 indexed pid, uint256 amount, address indexed to);
    event EmergencyWithdraw(address indexed user, uint256 indexed pid, uint256 amount, address indexed to);
    event Harvest(address indexed user, uint256 indexed pid, uint256 amount);
    event LogPoolAddition(uint256 indexed pid, uint256 allocPoint, IERC20 indexed lpToken, IRewarder indexed rewarder);
    event LogSetPool(uint256 indexed pid, uint256 allocPoint, IRewarder indexed rewarder, bool overwrite);
    event LogUpdatePool(uint256 indexed pid, uint64 lastRewardBlock, uint256 lpSupply, uint256 accJoePerShare);
    event LogInit();

    /// @param _MASTER_CHEF The JoeSwap MCV1 contract address.
    /// @param _joe The JOE token contract address.
    /// @param _MASTER_PID The pool ID of the dummy token on the base MCV1 contract.
    constructor(IMasterJoe _MASTER_CHEF, IERC20 _joe, uint256 _MASTER_PID) public {
        MASTER_CHEF = _MASTER_CHEF;
        JOE = _joe;
        MASTER_PID = _MASTER_PID;
    }

    /// @notice Deposits a dummy token to `MASTER_CHEF` MCV1. This is required because MCV1 holds the minting rights for JOE.
    /// Any balance of transaction sender in `dummyToken` is transferred.
    /// The allocation point for the pool on MCV1 is the total allocation point for all pools that receive double incentives.
    /// @param dummyToken The address of the ERC-20 token to deposit into MCV1.
    function init(IERC20 dummyToken) external {
        uint256 balance = dummyToken.balanceOf(msg.sender);
        require(balance != 0, "MasterJoeV2: Balance must exceed 0");
        dummyToken.safeTransferFrom(msg.sender, address(this), balance);
        dummyToken.approve(address(MASTER_CHEF), balance);
        MASTER_CHEF.deposit(MASTER_PID, balance);
        emit LogInit();
    }

    /// @notice Returns the number of MCV2 pools.
    function poolLength() public view returns (uint256 pools) {
        pools = poolInfo.length;
    }

    /// @notice Add a new LP to the pool. Can only be called by the owner.
    /// DO NOT add the same LP token more than once. Rewards will be messed up if you do.
    /// @param allocPoint AP of the new pool.
    /// @param _lpToken Address of the LP ERC-20 token.
    /// @param _rewarder Address of the rewarder delegate.
    function add(uint256 allocPoint, IERC20 _lpToken, IRewarder _rewarder) public onlyOwner {
        uint256 lastRewardBlock = block.number;
        totalAllocPoint = totalAllocPoint.add(allocPoint);
        lpToken.push(_lpToken);
        rewarder.push(_rewarder);

        poolInfo.push(PoolInfo({
            allocPoint: allocPoint.to64(),
            lastRewardBlock: lastRewardBlock.to64(),
            accJoePerShare: 0
        }));
        emit LogPoolAddition(lpToken.length.sub(1), allocPoint, _lpToken, _rewarder);
    }

    /// @notice Update the given pool's JOE allocation point and `IRewarder` contract. Can only be called by the owner.
    /// @param _pid The index of the pool. See `poolInfo`.
    /// @param _allocPoint New AP of the pool.
    /// @param _rewarder Address of the rewarder delegate.
    /// @param overwrite True if _rewarder should be `set`. Otherwise `_rewarder` is ignored.
    function set(uint256 _pid, uint256 _allocPoint, IRewarder _rewarder, bool overwrite) public onlyOwner {
        totalAllocPoint = totalAllocPoint.sub(poolInfo[_pid].allocPoint).add(_allocPoint);
        poolInfo[_pid].allocPoint = _allocPoint.to64();
        if (overwrite) { rewarder[_pid] = _rewarder; }
        emit LogSetPool(_pid, _allocPoint, overwrite ? _rewarder : rewarder[_pid], overwrite);
    }

    /// @notice Set the `migrator` contract. Can only be called by the owner.
    /// @param _migrator The contract address to set.
    function setMigrator(IMigratorJoe _migrator) public onlyOwner {
        migrator = _migrator;
    }

    /// @notice Migrate LP token to another LP contract through the `migrator` contract.
    /// @param _pid The index of the pool. See `poolInfo`.
    function migrate(uint256 _pid) public {
        require(address(migrator) != address(0), "MasterJoeV2: no migrator set");
        IERC20 _lpToken = lpToken[_pid];
        uint256 bal = _lpToken.balanceOf(address(this));
        _lpToken.approve(address(migrator), bal);
        IERC20 newLpToken = migrator.migrate(_lpToken);
        require(bal == newLpToken.balanceOf(address(this)), "MasterJoeV2: migrated balance must match");
        lpToken[_pid] = newLpToken;
    }

    /// @notice View function to see pending JOE on frontend.
    /// @param _pid The index of the pool. See `poolInfo`.
    /// @param _user Address of user.
    /// @return pending JOE reward for a given user.
    function pendingJoe(uint256 _pid, address _user) external view returns (uint256 pending) {
        PoolInfo memory pool = poolInfo[_pid];
        UserInfo storage user = userInfo[_pid][_user];
        uint256 accJoePerShare = pool.accJoePerShare;
        uint256 lpSupply = lpToken[_pid].balanceOf(address(this));
        if (block.number > pool.lastRewardBlock && lpSupply != 0) {
            uint256 blocks = block.number.sub(pool.lastRewardBlock);
            uint256 joeReward = blocks.mul(joePerBlock()).mul(pool.allocPoint) / totalAllocPoint;
            accJoePerShare = accJoePerShare.add(joeReward.mul(ACC_JOE_PRECISION) / lpSupply);
        }
        pending = int256(user.amount.mul(accJoePerShare) / ACC_JOE_PRECISION).sub(user.rewardDebt).toUInt256();
    }

    /// @notice Update reward variables for all pools. Be careful of gas spending!
    /// @param pids Pool IDs of all to be updated. Make sure to update all active pools.
    function massUpdatePools(uint256[] calldata pids) external {
        uint256 len = pids.length;
        for (uint256 i = 0; i < len; ++i) {
            updatePool(pids[i]);
        }
    }

    /// @notice Calculates and returns the `amount` of JOE per block.
    function joePerBlock() public view returns (uint256 amount) {
        amount = uint256(MASTERCHEF_JOE_PER_BLOCK)
            .mul(MASTER_CHEF.poolInfo(MASTER_PID).allocPoint) / MASTER_CHEF.totalAllocPoint();
    }

    /// @notice Update reward variables of the given pool.
    /// @param pid The index of the pool. See `poolInfo`.
    /// @return pool Returns the pool that was updated.
    function updatePool(uint256 pid) public returns (PoolInfo memory pool) {
        pool = poolInfo[pid];
        if (block.number > pool.lastRewardBlock) {
            uint256 lpSupply = lpToken[pid].balanceOf(address(this));
            if (lpSupply > 0) {
                uint256 blocks = block.number.sub(pool.lastRewardBlock);
                uint256 joeReward = blocks.mul(joePerBlock()).mul(pool.allocPoint) / totalAllocPoint;
                pool.accJoePerShare = pool.accJoePerShare.add((joeReward.mul(ACC_JOE_PRECISION) / lpSupply).to128());
            }
            pool.lastRewardBlock = block.number.to64();
            poolInfo[pid] = pool;
            emit LogUpdatePool(pid, pool.lastRewardBlock, lpSupply, pool.accJoePerShare);
        }
    }

    /// @notice Deposit LP tokens to MCV2 for JOE allocation.
    /// @param pid The index of the pool. See `poolInfo`.
    /// @param amount LP token amount to deposit.
    /// @param to The receiver of `amount` deposit benefit.
    function deposit(uint256 pid, uint256 amount, address to) public {
        PoolInfo memory pool = updatePool(pid);
        UserInfo storage user = userInfo[pid][to];

        // Effects
        user.amount = user.amount.add(amount);
        user.rewardDebt = user.rewardDebt.add(int256(amount.mul(pool.accJoePerShare) / ACC_JOE_PRECISION));

        // Interactions
        lpToken[pid].safeTransferFrom(msg.sender, address(this), amount);

        emit Deposit(msg.sender, pid, amount, to);
    }

    /// @notice Withdraw LP tokens from MCV2.
    /// @param pid The index of the pool. See `poolInfo`.
    /// @param amount LP token amount to withdraw.
    /// @param to Receiver of the LP tokens.
    function withdraw(uint256 pid, uint256 amount, address to) public {
        PoolInfo memory pool = updatePool(pid);
        UserInfo storage user = userInfo[pid][msg.sender];

        // Effects
        user.rewardDebt = user.rewardDebt.sub(int256(amount.mul(pool.accJoePerShare) / ACC_JOE_PRECISION));
        user.amount = user.amount.sub(amount);

        // Interactions
        lpToken[pid].safeTransfer(to, amount);

        emit Withdraw(msg.sender, pid, amount, to);
    }

    /// @notice Harvest proceeds for transaction sender to `to`.
    /// @param pid The index of the pool. See `poolInfo`.
    /// @param to Receiver of JOE rewards.
    /// @return success Returns bool indicating success of rewarder delegate call.
    function harvest(uint256 pid, address to) public returns (bool success) {
        PoolInfo memory pool = updatePool(pid);
        UserInfo storage user = userInfo[pid][msg.sender];
        int256 accumulatedJoe = int256(user.amount.mul(pool.accJoePerShare) / ACC_JOE_PRECISION);
        uint256 _pendingJoe = accumulatedJoe.sub(user.rewardDebt).toUInt256();
        if (_pendingJoe == 0) { success = false; }

        // Effects
        user.rewardDebt = accumulatedJoe;

        // Interactions
        JOE.safeTransfer(to, _pendingJoe);

        address _rewarder = address(rewarder[pid]);
        if (_rewarder != address(0)) {
            // Note: Do it this way because we don't want to fail harvest if only the delegate call fails.
            // Additionally, forward less gas so that we have enough buffer to complete harvest if the call eats up too much gas.
            // Forwarding: (63/64 of gasleft by evm convention) minus 5000
            // solhint-disable-next-line
            (success, ) = _rewarder.call{ gas: gasleft() - 5000 }(abi.encodeWithSelector(SIG_ON_JOE_REWARD, pid, msg.sender, _pendingJoe));
        }

        emit Harvest(msg.sender, pid, _pendingJoe);
    }

    /// @notice Harvests JOE from `MASTER_CHEF` MCV1 and pool `MASTER_PID` to this MCV2 contract.
    function harvestFromMasterJoe() public {
        MASTER_CHEF.deposit(MASTER_PID, 0);
    }

    /// @notice Withdraw without caring about rewards. EMERGENCY ONLY.
    /// @param pid The index of the pool. See `poolInfo`.
    /// @param to Receiver of the LP tokens.
    function emergencyWithdraw(uint256 pid, address to) public {
        UserInfo storage user = userInfo[pid][msg.sender];
        uint256 amount = user.amount;
        user.amount = 0;
        user.rewardDebt = 0;
        // Note: transfer can fail or succeed if `amount` is zero.
        lpToken[pid].safeTransfer(to, amount);
        emit EmergencyWithdraw(msg.sender, pid, amount, to);
    }
}
