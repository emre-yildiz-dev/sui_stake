module stake::staking {
    use sui::coin::{Self, Coin};
    use sui::balance::{Self, Balance};
    use sui::clock::{Self, Clock};
    use sui::table::{Self, Table};
    use sui::event;
    use tiu::tiu::TIU;

    // Error codes
    const EStakerDoesNotExist: u64 = 0;
    const EInvalidStakePeriod: u64 = 1;
    const EInvalidPlanIndex: u64 = 2;
    const EStakingIsPaused: u64 = 3;
    const EUnstakeDelayNotMet: u64 = 4;

    // Constants
    const SECONDS_PER_DAY: u64 = 86400;
    const DAYS_PER_YEAR: u64 = 365;
    const SCALE: u64 = 10000; // For percentage calculations

    // Staking periods in seconds
    const PERIOD_90_DAYS: u64 = 90 * SECONDS_PER_DAY;
    const PERIOD_180_DAYS: u64 = 180 * SECONDS_PER_DAY;
    const PERIOD_365_DAYS: u64 = 365 * SECONDS_PER_DAY;


    public struct AdminCap has key, store {
       id: UID,
    }

    public struct StakingPool has key {
        id: UID,
        staking_balance: Balance<TIU>,
        reward_pool: Balance<TIU>,
        stakes: Table<address, Table<u64, Stake>>,
        unstake_requests: Table<address, Table<u64, UnstakeRequest>>,
        staking_plans: vector<StakingPlan>,
        total_staked: u64,
        unstake_delay: u64,
        early_unstake_penalty_rate: u64,
        is_paused: bool,
    }

    public struct StakingPlan has copy, store {
        index: u64,
        duration: u64,
        apy: u64,
        is_active: bool
    }

    public struct Stake has store {
        user: address,
        amount: u64,
        start_time: u64,
        end_time: u64,
        plan: StakingPlan,
        state: u8 // 0: Staked, 1: UnstakeRequested, 2: Withdrawn
    }

    public struct UnstakeRequest has store {
        user: address,
        stake_index: u64,
        request_time: u64,
        penalty_amount: u64
    }

    // Events
    public struct StakeEvent has copy, drop {
        user: address,
        amount: u64,
        plan_index: u64
    }

    public struct UnstakeRequestEvent has copy, drop {
        user: address,
        stake_index: u64,
        penalty_amount: u64
    }

    public struct UnstakedEvent has copy, drop {
        user: address,
        amount: u64,
        reward: u64,
        penalty: u64
    }

    // Entry function
    fun init(ctx: &mut TxContext) {
        let sender = tx_context::sender(ctx);

        // Create and transfer admin cap
        create_and_transfer_admin_cap(sender, ctx);

        // Initialize and transfer staking pool
        initialize_staking_pool_and_transfer(ctx);
    }

    fun create_and_transfer_admin_cap(sender: address, ctx: &mut TxContext) {
        let admin_cap = AdminCap {
            id: object::new(ctx),
        };
        transfer::public_transfer(admin_cap, sender);
    }

    fun initialize_staking_pool_and_transfer(ctx: &mut TxContext) {
     let staking_pool = StakingPool {
            id: object::new(ctx),
            staking_balance: balance::zero(),
            reward_pool: balance::zero(),
            stakes: table::new(ctx),
            unstake_requests: table::new(ctx),
            staking_plans: vector[
                StakingPlan { index: 0, duration: PERIOD_90_DAYS, apy: 1000, is_active: true },  // 10%
                StakingPlan { index: 1, duration: PERIOD_180_DAYS, apy: 1500, is_active: true }, // 15%
                StakingPlan { index: 2, duration: PERIOD_365_DAYS, apy: 2000, is_active: true }  // 20%
            ],
            total_staked: 0,
            unstake_delay: 1 * SECONDS_PER_DAY, // 1 day
            early_unstake_penalty_rate: 1000, // 10%
            is_paused: false,
        };
        transfer::share_object(staking_pool);
    }

    public entry fun stake(
        pool: &mut StakingPool,
        coin: &mut Coin<TIU>,
        amount: u64,
        plan_index: u64,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        // Validate conditions
        assert!(!pool.is_paused, EStakingIsPaused);

        let sender = tx_context::sender(ctx);
        let plans = &pool.staking_plans;
        assert!(plan_index < vector::length(plans), EInvalidStakePeriod);
        
        let plan = *vector::borrow(plans, plan_index);
        assert!(plan.is_active, EInvalidStakePeriod);

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
            user: sender,
            amount,
            start_time: current_time,
            end_time: current_time + plan.duration,
            plan: plan,
            state: 0 // Staked
        };

        table::add(user_stakes, stake_id, stake);
        pool.total_staked = pool.total_staked + amount;

        // Emit event
        event::emit(StakeEvent {
            user: sender,
            amount,
            plan_index
        });
    }

    public entry fun request_unstake(
        pool: &mut StakingPool,
        stake_index: u64,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        let sender = tx_context::sender(ctx);
        assert!(table::contains(&pool.stakes, sender), EStakerDoesNotExist);
        let user_stakes = table::borrow_mut(&mut pool.stakes, sender);
        assert!(stake_index < table::length(user_stakes), EInvalidStakePeriod);

        let stake = table::borrow_mut(user_stakes, stake_index);
        assert!(stake.state == 0, EInvalidStakePeriod); // Must be in Staked state

        let current_time = clock::timestamp_ms(clock) / 1000;
        let penalty_amount = if (current_time < stake.end_time) {
            (stake.amount * pool.early_unstake_penalty_rate) / SCALE
        } else {
            0
        };

        stake.state = 1; // UnstakeRequested

        // Initialize user's unstake request table if needed
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
            penalty_amount
        });
    }

    public entry fun process_unstake(
        _admin_cap: &AdminCap,
        pool: &mut StakingPool,
        stake_index: u64,
        clock: &Clock,
        ctx: &mut TxContext
    ) {
        let sender = tx_context::sender(ctx);
        let user_stakes = table::borrow_mut(&mut pool.stakes, sender);
        let stake = table::borrow_mut(user_stakes, stake_index);
        
        assert!(stake.state == 1, EInvalidStakePeriod); // Must be in UnstakeRequested state

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

        let amount_to_return = stake.amount - request.penalty_amount;

        // Transfer tokens
        let mut return_coins = coin::take(&mut pool.staking_balance, amount_to_return, ctx);

        if (reward > 0) {
            let reward_coins = coin::take(&mut pool.reward_pool, reward, ctx);
            coin::join(&mut return_coins, reward_coins);
        };

        transfer::public_transfer(return_coins, sender);

        // Update state
        stake.state = 2; // Withdrawn
        pool.total_staked = pool.total_staked - stake.amount;

        if (request.penalty_amount > 0) {
            let penalty_coins = coin::take(&mut pool.staking_balance, request.penalty_amount, ctx);
            coin::put(&mut pool.reward_pool, penalty_coins);
        };

        event::emit(UnstakedEvent {
            user: sender,
            amount: amount_to_return,
            reward,
            penalty: request.penalty_amount
        });
    }

    fun calculate_reward(stake: &Stake): u64 {
        (stake.amount * stake.plan.apy * stake.plan.duration) / (DAYS_PER_YEAR * SECONDS_PER_DAY * SCALE)
    }

    // Admin functions
    public entry fun add_to_reward_pool(
        _admin_cap: &AdminCap,
        pool: &mut StakingPool,
        coin: Coin<TIU>
    ) {
        coin::put(&mut pool.reward_pool, coin);
    }

    public entry fun toggle_pause(
        _admin_cap: &AdminCap,
        pool: &mut StakingPool,
    ) {
        pool.is_paused = !pool.is_paused;
    }

    public entry fun update_staking_plan(
        _admin_cap: &AdminCap,
        pool: &mut StakingPool,
        index: u64,
        apy: u64,
        is_active: bool
    ) {
        assert!(index < vector::length(&pool.staking_plans), EInvalidPlanIndex);
        let plan = vector::borrow_mut(&mut pool.staking_plans, index);
        plan.apy = apy;
        plan.is_active = is_active;
    }

    public entry fun add_staking_plan(
        _admin_cap: &AdminCap,
        pool: &mut StakingPool,
        duration: u64,
        apy: u64,
        is_active: bool
    ) {
        let index  = vector::length(&pool.staking_plans);
        vector::push_back(&mut pool.staking_plans, StakingPlan {
            index,
            duration,
            apy,
            is_active
        });
    }

    public entry fun set_early_unstake_penalty_rate(
        _admin_cap: &AdminCap,
        pool: &mut StakingPool,
        rate: u64
    ) {
        pool.early_unstake_penalty_rate = rate;
    }

    public entry fun set_unstake_delay(
        _admin_cap: &AdminCap,
        pool: &mut StakingPool,
        delay: u64
    ) {
        pool.unstake_delay = delay;
    }

    // View functions
    public fun get_stake_info(pool: &StakingPool, user: address, stake_index: u64): (u64, u64, u64, u64) {
        assert!(table::contains(&pool.stakes, user), EStakerDoesNotExist);
        let user_stakes = table::borrow(&pool.stakes, user);
        let stake = table::borrow(user_stakes, stake_index);
        (stake.amount, stake.start_time, stake.end_time, stake.plan.duration)
    }

    public fun get_total_staked(pool: &StakingPool): u64 {
        pool.total_staked
    }

    public fun get_reward_pool(pool: &StakingPool): u64 {
        balance::value(&pool.reward_pool)
    }
}