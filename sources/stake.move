module stake::staking {
    use sui::coin::{Self, Coin};
    use sui::balance::{Self, Balance};
    use sui::clock::{Self, Clock};
    use sui::table::{Self, Table};
    use sui::event;
    use zzz::zzz::ZZZ;

    const VERSION: u64 = 1;

    // Error codes
    const EStakerDoesNotExist: u64 = 0;
    const EInvalidStakePeriod: u64 = 1;
    const EInvalidPlanIndex: u64 = 2;
    const EStakingIsPaused: u64 = 3;
    const EUnstakeDelayNotMet: u64 = 4;
    const EInvalidAmount: u64 = 5;
    const EMaxStakesReached: u64 = 6;
    const EInsufficientRewardPool: u64 = 7;
    const EPoolLimitExceeded: u64 = 8;
    const EUnauthorized: u64 = 9;
    const EZeroAmount: u64 = 10;
    const EInvalidVersion: u64 = 11;
    const EWrongAdmin: u64 = 12;
    const ENotEmergencyMode: u64 = 13;

    // Constants
    const SECONDS_PER_DAY: u64 = 86400;
    const DAYS_PER_YEAR: u64 = 365;
    const SCALE: u64 = 10000; // For percentage calculations
    const COIN_DECIMALS: u64 = 3;
    const DECIMAL_SCALING: u64 = 1000; // 10^3

    // Staking periods in seconds
    const PERIOD_90_DAYS: u64 = 90 * SECONDS_PER_DAY;
    const PERIOD_180_DAYS: u64 = 180 * SECONDS_PER_DAY;
    const PERIOD_365_DAYS: u64 = 365 * SECONDS_PER_DAY;

    // Configuration constants
    const MIN_STAKE_AMOUNT: u64 = 10_000_000_000 * DECIMAL_SCALING; // 10B tokens
    const MAX_STAKE_AMOUNT: u64 = 90_000_000_000_000 * DECIMAL_SCALING; // 90B tokens
    const MAX_POOL_BALANCE: u64 = 900_000_000_000_000 * DECIMAL_SCALING; // 900B tokens
    const MAX_STAKES_PER_USER: u64 = 100;

    public struct AdminCap has key, store {
        id: UID,
    }

    public struct StakingPool has key {
        id: UID,
        version: u64,
        admin_id: ID,
        staking_balance: Balance<ZZZ>,
        reward_pool: Balance<ZZZ>,
        stakes: Table<address, Table<u64, Stake>>,
        unstake_requests: Table<address, Table<u64, UnstakeRequest>>,
        staking_plans: vector<StakingPlan>,
        total_staked: u64,
        unstake_delay: u64,
        early_unstake_penalty_rate: u64,
        is_paused: bool,
        emergency_mode: bool,
        min_stake_amount: u64,
        max_stake_amount: u64,
        max_pool_balance: u64,
        max_stakes_per_user: u64,
    }

    public struct StakingPoolInfo has copy, store {
        total_staked: u64,
        staking_balance: u64,
        reward_pool_balance: u64,
        is_paused: bool,
        emergency_mode: bool,
        min_stake_amount: u64,
        max_stake_amount: u64,
        max_pool_balance: u64,
        max_stakes_per_user: u64,
    }

    public struct StakingPlan has copy, store {
        index: u64,
        duration: u64,
        apy: u64,
        is_active: bool,
        min_stake_amount: u64,
        max_stake_amount: u64,
    }

    public struct Stake has store {
        index: u64,
        user: address,
        amount: u64,
        start_time: u64,
        end_time: u64,
        plan: StakingPlan,
        state: StakeState
    }

    public struct UnstakeRequest has store {
        user: address,
        stake_index: u64,
        request_time: u64,
        penalty_amount: u64
    }

    public enum StakeState has copy, store, drop {
        Staked,
        UnstakeRequested,
        Withdrawn
    }

    public struct StakeMetadata has key, store {
        id: UID,
        coin_package: address,
        coin_type: vector<u8>,
        coin_decimals: u64,
    }

    // Enhanced struct for detailed stake status
    public struct StakeStatus has copy, drop {
        is_mature: bool,
        can_unstake: bool,
        pending_reward: u64,
        potential_penalty: u64
    }

    // Enhanced Events
    public struct StakeEvent has copy, drop {
        user: address,
        amount: u64,
        plan_index: u64,
        timestamp: u64
    }

    public struct UnstakeRequestEvent has copy, drop {
        user: address,
        stake_index: u64,
        penalty_amount: u64,
        timestamp: u64
    }

    public struct UnstakedEvent has copy, drop {
        user: address,
        amount: u64,
        reward: u64,
        penalty: u64,
        timestamp: u64
    }

    public struct PlanUpdateEvent has copy, drop {
        index: u64,
        new_apy: u64,
        is_active: bool,
        timestamp: u64
    }

    public struct EmergencyActionEvent has copy, drop {
        action_type: u8, // 0: pause, 1: emergency withdraw
        amount: u64,
        timestamp: u64
    }

    public struct PoolLimitUpdateEvent has copy, drop {
        new_limit: u64,
        timestamp: u64
    }

    public struct PoolLimitsUpdateEvent has copy, drop {
        new_min_stake: u64,
        new_max_stake: u64,
        new_pool_balance: u64,
        new_max_stakes: u64,
        timestamp: u64
    }

    public struct RewardPoolUpdateEvent has copy, drop {
        amount_added: u64,
        new_balance: u64,
        timestamp: u64
    }

    // Add this new event struct with the other events
    public struct RewardPoolWithdrawEvent has copy, drop {
        amount_withdrawn: u64,
        recipient: address,
        remaining_balance: u64,
        timestamp: u64
    }

    fun init(ctx: &mut TxContext) {
        let sender = tx_context::sender(ctx);

        // Initialize staking metadata
        initialize_staking_metadata(ctx);

        // Create and transfer admin cap
          let admin_cap = AdminCap {
            id: object::new(ctx),
        };

        // Initialize staking pool
        initialize_staking_pool_and_transfer(object::id(&admin_cap), ctx);

        // Transfer admin cap
        transfer::public_transfer(admin_cap, sender);
    }

    fun initialize_staking_metadata(ctx: &mut TxContext) {
        let zzz_package = @zzz_package;
        let mut zzz_package_str = zzz_package.to_string();
        zzz_package_str.append_utf8(b"::zzz::ZZZ");
        let staking_metadata = StakeMetadata {
            id: object::new(ctx),
            coin_package: @zzz_package,
            coin_type: *zzz_package_str.as_bytes(),
            coin_decimals: COIN_DECIMALS,
        };
        transfer::freeze_object(staking_metadata);
    }

    fun initialize_staking_pool_and_transfer(admin_id: ID, ctx: &mut TxContext) {
        let staking_pool = StakingPool {
            id: object::new(ctx),
            version: VERSION,
            admin_id,
            staking_balance: balance::zero(),
            reward_pool: balance::zero(),
            stakes: table::new(ctx),
            unstake_requests: table::new(ctx),
            staking_plans: vector[
                StakingPlan { 
                    index: 0, 
                    duration: PERIOD_90_DAYS, 
                    apy: 500, 
                    is_active: true,
                    min_stake_amount: MIN_STAKE_AMOUNT,
                    max_stake_amount: MAX_STAKE_AMOUNT
                },
                StakingPlan { 
                    index: 1, 
                    duration: PERIOD_180_DAYS, 
                    apy: 1000, 
                    is_active: true,
                    min_stake_amount: MIN_STAKE_AMOUNT,
                    max_stake_amount: MAX_STAKE_AMOUNT
                },
                StakingPlan { 
                    index: 2, 
                    duration: PERIOD_365_DAYS, 
                    apy: 1500, 
                    is_active: true,
                    min_stake_amount: MIN_STAKE_AMOUNT,
                    max_stake_amount: MAX_STAKE_AMOUNT
                }
            ],
            total_staked: 0,
            // unstake_delay: 1 * SECONDS_PER_DAY,
            unstake_delay: 3 * SECONDS_PER_DAY,
            early_unstake_penalty_rate: 500,
            is_paused: false,
            emergency_mode: false,
            min_stake_amount: MIN_STAKE_AMOUNT,
            max_stake_amount: MAX_STAKE_AMOUNT,
            max_pool_balance: MAX_POOL_BALANCE,
            max_stakes_per_user: MAX_STAKES_PER_USER,
        };
        transfer::share_object(staking_pool);
    }

    public entry fun stake(
        pool: &mut StakingPool,
        coin: &mut Coin<ZZZ>,
        amount: u64,
        plan_index: u64,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        // Enhanced validation
        assert!(!pool.is_paused, EStakingIsPaused);
        assert!(!pool.emergency_mode, EStakingIsPaused);
        assert!(amount > 0, EZeroAmount);
        assert!(pool.version == VERSION, EInvalidVersion);
        
        let sender = tx_context::sender(ctx);
        let plans = &pool.staking_plans;
        assert!(plan_index < vector::length(plans), EInvalidPlanIndex);
        
        let plan = *vector::borrow(plans, plan_index);
        assert!(plan.is_active, EInvalidStakePeriod);
        assert!(amount >= pool.min_stake_amount, EInvalidAmount);
        assert!(amount <= pool.max_stake_amount, EInvalidAmount);
        assert!(pool.total_staked + amount <= pool.max_pool_balance, EPoolLimitExceeded);

        // Check user's stake count
        if (table::contains(&pool.stakes, sender)) {
            let user_stakes = table::borrow(&pool.stakes, sender);
            assert!(table::length(user_stakes) < pool.max_stakes_per_user, EMaxStakesReached);
        };

        // Transfer tokens
        let stake_coins = coin::split(coin, amount, ctx);
        coin::put(&mut pool.staking_balance, stake_coins);

        // Initialize user's stake table if needed
        if (!table::contains(&pool.stakes, sender)) {
            table::add(&mut pool.stakes, sender, table::new(ctx));
        };

        let user_stakes = table::borrow_mut(&mut pool.stakes, sender);
        let stake_id = table::length(user_stakes);
        
        let current_time = clock::timestamp_ms(clock) / 1000;
        
        // Create stake
        let stake = Stake {
            index: stake_id,
            user: sender,
            amount,
            start_time: current_time,
            end_time: current_time + plan.duration,
            plan,
            state: StakeState::Staked
        };

        table::add(user_stakes, stake_id, stake);
        pool.total_staked = pool.total_staked + amount;

        // Enhanced event
        event::emit(StakeEvent {
            user: sender,
            amount,
            plan_index,
            timestamp: current_time
        });
    }

    public entry fun request_unstake(
        pool: &mut StakingPool,
        stake_index: u64,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        assert!(pool.version == VERSION, EInvalidVersion);

        let sender = tx_context::sender(ctx);
        assert!(table::contains(&pool.stakes, sender), EStakerDoesNotExist);
        
        let user_stakes = table::borrow_mut(&mut pool.stakes, sender);
        assert!(stake_index < table::length(user_stakes), EInvalidStakePeriod);

        let stake = table::borrow_mut(user_stakes, stake_index);
        assert!(stake.state == StakeState::Staked, EInvalidStakePeriod);

        let current_time = clock::timestamp_ms(clock) / 1000;
        let penalty_amount = if (current_time < stake.end_time) {
            (stake.amount * pool.early_unstake_penalty_rate) / SCALE
        } else {
            0
        };

        stake.state = StakeState::UnstakeRequested;

        if (!table::contains(&pool.unstake_requests, sender)) {
            table::add(&mut pool.unstake_requests, sender, table::new(ctx));
        };

        let user_requests = table::borrow_mut(&mut pool.unstake_requests, sender);
        let request = UnstakeRequest {
            user: sender,
            stake_index,
            request_time: current_time,
            penalty_amount
        };

        table::add(user_requests, stake_index, request);

        event::emit(UnstakeRequestEvent {
            user: sender,
            stake_index,
            penalty_amount,
            timestamp: current_time
        });
    }

    public entry fun process_unstake(
        pool: &mut StakingPool,
        stake_index: u64,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        assert!(pool.version == VERSION, EInvalidVersion);

        assert!(!pool.is_paused, EStakingIsPaused);
        let sender = tx_context::sender(ctx);
        let user_stakes = table::borrow_mut(&mut pool.stakes, sender);
        let stake = table::borrow_mut(user_stakes, stake_index);
        
        assert!(stake.state == StakeState::UnstakeRequested, EInvalidStakePeriod);

        let user_requests = table::borrow(&pool.unstake_requests, sender);
        let request = table::borrow(user_requests, stake_index);
        
        let current_time = clock::timestamp_ms(clock) / 1000;
        
        assert!(
            current_time >= request.request_time + pool.unstake_delay,
            EUnstakeDelayNotMet
        );

        let reward = if (current_time >= stake.end_time && request.penalty_amount == 0) {
            calculate_reward(stake)
        } else {
            0
        };

        // Verify reward pool has sufficient funds
        if (reward > 0) {
            assert!(balance::value(&pool.reward_pool) >= reward, EInsufficientRewardPool);
        };

        let amount_to_return = stake.amount - request.penalty_amount;
        assert!(amount_to_return > 0, EZeroAmount);

        // Transfer tokens
        let mut return_coins = coin::take(&mut pool.staking_balance, amount_to_return, ctx);

        if (reward > 0) {
            let reward_coins = coin::take(&mut pool.reward_pool, reward, ctx);
            coin::join(&mut return_coins, reward_coins);
        };

        transfer::public_transfer(return_coins, sender);

        stake.state = StakeState::Withdrawn;
        pool.total_staked = pool.total_staked - stake.amount;

        if (request.penalty_amount > 0) {
            let penalty_coins = coin::take(&mut pool.staking_balance, request.penalty_amount, ctx);
            coin::put(&mut pool.reward_pool, penalty_coins);
        };

        event::emit(UnstakedEvent {
            user: sender,
            amount: amount_to_return,
            reward,
            penalty: request.penalty_amount,
            timestamp: current_time
        });
    }

    // Emergency Functions
    public entry fun emergency_pause(
        _admin_cap: &AdminCap,
        pool: &mut StakingPool,
        clock: &Clock
    ) {
        assert!(pool.version == VERSION, EInvalidVersion);

        pool.emergency_mode = true;
        pool.is_paused = true;
        
        event::emit(EmergencyActionEvent {
            action_type: 0,
            amount: 0,
            timestamp: clock::timestamp_ms(clock) / 1000
        });
    }

    public entry fun emergency_withdraw(
        _admin_cap: &AdminCap,
        pool: &mut StakingPool,
        amount: u64,
        recipient: address,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        assert!(pool.version == VERSION, EInvalidVersion);
        assert!(pool.emergency_mode, ENotEmergencyMode);
        assert!(amount > 0, EZeroAmount);
        
        let coins = coin::take(&mut pool.staking_balance, amount, ctx);
        transfer::public_transfer(coins, recipient);
        
        event::emit(EmergencyActionEvent {
            action_type: 1,
            amount,
            timestamp: clock::timestamp_ms(clock) / 1000
        });
    }

    // Enhanced Admin Functions
    public entry fun update_staking_plan(
        _admin_cap: &AdminCap,
        pool: &mut StakingPool,
        index: u64,
        apy: u64,
        is_active: bool,
        min_amount: u64,
        max_amount: u64,
        clock: &Clock
    ) {
        assert!(pool.version == VERSION, EInvalidVersion);
        assert!(index < vector::length(&pool.staking_plans), EInvalidPlanIndex);

        let plan = vector::borrow_mut(&mut pool.staking_plans, index);
        plan.apy = apy;
        plan.is_active = is_active;
        plan.min_stake_amount = min_amount;
        plan.max_stake_amount = max_amount;

        event::emit(PlanUpdateEvent {
            index,
            new_apy: apy,
            is_active,
            timestamp: clock::timestamp_ms(clock) / 1000
        });
    }

    public fun get_pool_info(pool: &StakingPool): StakingPoolInfo {
        assert!(pool.version == VERSION, EInvalidVersion);

        StakingPoolInfo {
            total_staked: pool.total_staked,
            staking_balance: balance::value(&pool.staking_balance),
            reward_pool_balance: balance::value(&pool.reward_pool),
            is_paused: pool.is_paused,
            emergency_mode: pool.emergency_mode,
            min_stake_amount: pool.min_stake_amount,
            max_stake_amount: pool.max_stake_amount,
            max_pool_balance: pool.max_pool_balance,
            max_stakes_per_user: pool.max_stakes_per_user
        }
    }

    public entry fun get_stake_info(pool: &StakingPool, user: address, stake_index: u64): 
        (u64, u64, u64, u64, StakeState) 
    {
        assert!(pool.version == VERSION, EInvalidVersion);

        assert!(table::contains(&pool.stakes, user), EStakerDoesNotExist);
        let user_stakes = table::borrow(&pool.stakes, user);
        let stake = table::borrow(user_stakes, stake_index);
        (
            stake.amount,
            stake.start_time,
            stake.end_time,
            stake.plan.duration,
            stake.state
        )
    }

    public fun get_staking_plan_info(pool: &StakingPool, plan_index: u64): 
        (u64, u64, u64, bool, u64, u64) 
    {
        assert!(pool.version == VERSION, EInvalidVersion);
        assert!(plan_index < vector::length(&pool.staking_plans), EInvalidPlanIndex);
        let plan = vector::borrow(&pool.staking_plans, plan_index);
        (
            plan.duration,
            plan.apy,
            plan.index,
            plan.is_active,
            plan.min_stake_amount,
            plan.max_stake_amount
        )
    }

    public fun get_unstake_request_info(
        pool: &StakingPool,
        user: address,
        stake_index: u64
    ): (u64, u64, u64) {
        assert!(pool.version == VERSION, EInvalidVersion);
        assert!(table::contains(&pool.unstake_requests, user), EStakerDoesNotExist);
        let user_requests = table::borrow(&pool.unstake_requests, user);
        let request = table::borrow(user_requests, stake_index);
        (
            request.request_time,
            request.penalty_amount,
            pool.unstake_delay
        )
    }

    // Enhanced Admin Configuration Functions
    public entry fun update_pool_limits(
        _admin_cap: &AdminCap,
        pool: &mut StakingPool,
        new_unstake_delay: u64,
        new_penalty_rate: u64,
        clock: &Clock
    ) {
        assert!(pool.version == VERSION, EInvalidVersion);

        pool.unstake_delay = new_unstake_delay;
        pool.early_unstake_penalty_rate = new_penalty_rate;

        event::emit(PoolLimitUpdateEvent {
            new_limit: new_penalty_rate,
            timestamp: clock::timestamp_ms(clock) / 1000
        });
    }

    public entry fun resume_from_emergency(
        _admin_cap: &AdminCap,
        pool: &mut StakingPool,
        clock: &Clock
    ) {
        assert!(pool.version == VERSION, EInvalidVersion);
        assert!(pool.emergency_mode, EUnauthorized);
        pool.emergency_mode = false;
        pool.is_paused = false;

        event::emit(EmergencyActionEvent {
            action_type: 2, // 2 for resume
            amount: 0,
            timestamp: clock::timestamp_ms(clock) / 1000
        });
    }

    public entry fun update_stake_limits(
        _admin_cap: &AdminCap,
        pool: &mut StakingPool,
        new_min_stake: u64,
        new_max_stake: u64,
        clock: &Clock
    ) {
        assert!(pool.version == VERSION, EInvalidVersion);
        assert!(new_min_stake <= new_max_stake, EInvalidAmount);
        pool.min_stake_amount = new_min_stake;
        pool.max_stake_amount = new_max_stake;

        event::emit(PoolLimitsUpdateEvent {
            new_min_stake,
            new_max_stake,
            new_pool_balance: pool.max_pool_balance,
            new_max_stakes: pool.max_stakes_per_user,
            timestamp: clock::timestamp_ms(clock) / 1000
        });
    }

    public entry fun update_pool_balance_limit(
        _admin_cap: &AdminCap,
        pool: &mut StakingPool,
        new_max_pool_balance: u64,
        clock: &Clock
    ) {
        assert!(pool.version == VERSION, EInvalidVersion);
        assert!(new_max_pool_balance >= pool.total_staked, EInvalidAmount);
        pool.max_pool_balance = new_max_pool_balance;

        event::emit(PoolLimitsUpdateEvent {
            new_min_stake: pool.min_stake_amount,
            new_max_stake: pool.max_stake_amount,
            new_pool_balance: new_max_pool_balance,
            new_max_stakes: pool.max_stakes_per_user,
            timestamp: clock::timestamp_ms(clock) / 1000
        });
    }

    public entry fun update_max_stakes_per_user(
        _admin_cap: &AdminCap,
        pool: &mut StakingPool,
        new_max_stakes: u64,
        clock: &Clock
    ) {
        pool.max_stakes_per_user = new_max_stakes;

        event::emit(PoolLimitsUpdateEvent {
            new_min_stake: pool.min_stake_amount,
            new_max_stake: pool.max_stake_amount,
            new_pool_balance: pool.max_pool_balance,
            new_max_stakes,
            timestamp: clock::timestamp_ms(clock) / 1000
        });
    }

    // Utility Functions
    fun calculate_reward(stake: &Stake): u64 {
        // First divide amount by SCALE to reduce the multiplication size
        let scaled_amount = stake.amount / SCALE;
        
        // Then multiply by APY
        let amount_with_apy = scaled_amount * stake.plan.apy;
        
        // Calculate time ratio to further reduce the size
        let time_ratio = stake.plan.duration / (DAYS_PER_YEAR * SECONDS_PER_DAY);
        
        // Final calculation
        let base_reward = amount_with_apy * time_ratio;
        
        // Add minimum check
        if (base_reward == 0 && stake.amount > 0 && stake.plan.apy > 0) {
            1
        } else {
            base_reward
        }
    }

    fun is_stake_mature(stake: &Stake, current_time: u64): bool {
        current_time >= stake.end_time
    }

    public fun get_stake_status(
        pool: &StakingPool,
        user: address,
        stake_index: u64,
        clock: &Clock
    ): StakeStatus {
        let current_time = clock::timestamp_ms(clock) / 1000;
        let user_stakes = table::borrow(&pool.stakes, user);
        let stake = table::borrow(user_stakes, stake_index);
        
        let is_mature = is_stake_mature(stake, current_time);
        let pending_reward = if (is_mature) {
            calculate_reward(stake)
        } else {
            0
        };
        
        let potential_penalty = if (!is_mature) {
            (stake.amount * pool.early_unstake_penalty_rate) / SCALE
        } else {
            0
        };

        StakeStatus {
            is_mature,
            can_unstake: stake.state == StakeState::Staked,
            pending_reward,
            potential_penalty
        }
    }

    // Constants getters
    public fun get_min_stake_amount(): u64 { MIN_STAKE_AMOUNT }
    public fun get_max_stake_amount(): u64 { MAX_STAKE_AMOUNT }
    public fun get_max_pool_balance(): u64 { MAX_POOL_BALANCE }
    public fun get_max_stakes_per_user(): u64 { MAX_STAKES_PER_USER }

    // Add this function after the other admin functions
    public entry fun add_to_reward_pool(
        _admin_cap: &AdminCap,
        pool: &mut StakingPool,
        coins: Coin<ZZZ>,
        clock: &Clock
    ) {
        let amount = coin::value(&coins);
        assert!(amount > 0, EZeroAmount);
        
        // Add coins to reward pool
        coin::put(&mut pool.reward_pool, coins);

        // Emit event for tracking
        event::emit(RewardPoolUpdateEvent {
            amount_added: amount,
            new_balance: balance::value(&pool.reward_pool),
            timestamp: clock::timestamp_ms(clock) / 1000
        });
    }

    // Add this function after add_to_reward_pool
    public entry fun withdraw_from_reward_pool(
        _admin_cap: &AdminCap,
        pool: &mut StakingPool,
        amount: u64,
        recipient: address,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        // Validations
        assert!(amount > 0, EZeroAmount);
        let reward_balance = balance::value(&pool.reward_pool);
        assert!(reward_balance >= amount, EInsufficientRewardPool);
        
        // Take coins from reward pool
        let withdraw_coins = coin::take(&mut pool.reward_pool, amount, ctx);
        
        // Transfer to recipient
        transfer::public_transfer(withdraw_coins, recipient);

        // Emit withdrawal event
        event::emit(RewardPoolWithdrawEvent {
            amount_withdrawn: amount,
            recipient,
            remaining_balance: balance::value(&pool.reward_pool),
            timestamp: clock::timestamp_ms(clock) / 1000
        });
    }

    // Migrate functions
    public entry fun migrate(
        _admin_cap: &AdminCap,
        pool: &mut StakingPool,
    ) {
        assert!(pool.version < VERSION, EInvalidVersion);
        assert!(pool.admin_id == object::id(_admin_cap), EWrongAdmin);

        pool.version = VERSION;
    }
}
