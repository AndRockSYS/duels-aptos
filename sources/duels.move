module androcksys_framework::duels {
    use std::signer;
    use std::vector;
    use std::error;

    use aptos_framework::timestamp;
    use aptos_framework::event;

    use aptos_framework::randomness;

    use aptos_framework::aptos_coin::{AptosCoin};
    use aptos_framework::coin::{Self, Coin};

    const EBET_IS_TOO_SMALL: u64 = 001;
    const ELOW_BALANCE: u64 = 002;
    const EROUND_HAS_ENDED: u64 = 003;
    const EWRONG_ROUND_ID: u64 = 004;

    const OWNER_FEE: u64 = 10;
	const MIN_BET: u64 = 100000000;

    struct Round has store {
		winner: address,
		red: address,
		blue: address,

        pool: Coin<AptosCoin>,

		timestamp: u64
    }

    struct State has key, store {
        rounds: vector<Round>
    }

	#[event]
    struct CreateRound has drop, store {
        id: u64,
        player: address,
        pool: u64
    }

	#[event]
    struct EnterRound has drop, store {
        id: u64,
        player: address,
    }

	#[event]
    struct CloseRound has drop, store {
        id: u64
    }

	#[event]
    struct EndRound has drop, store {
        id: u64,
        winner: address,
        winning_amount: u64
    }

    fun init_module(owner: &signer) {
        move_to(owner, State { 
            rounds: vector::empty<Round>()
        });
    }

    public entry fun create_round(player: &signer, value: u64, isRed: bool) acquires State {
        assert!(value >= MIN_BET, error::invalid_argument(EBET_IS_TOO_SMALL));
        check_balance(signer::address_of(player), value);

        let player_address = signer::address_of(player);
		let coins = coin::withdraw<AptosCoin>(player, value);

        let new_round = Round {
			winner: @0x0,
			red: if (isRed) player_address else @0x0,
			blue: if (isRed) @0x0 else player_address,

        	pool: coins,

			timestamp: timestamp::now_seconds(),
        };

        let state = borrow_global_mut<State>(@androcksys_framework);
        vector::push_back<Round>(&mut state.rounds, new_round);

		event::emit(CreateRound {
			id: get_round_id(),
        	player: player_address,
        	pool: value
		});
    }

	#[lint::allow_unsafe_randomness]
    public entry fun enter_round(player: &signer, round_id: u64) acquires State {
        let state = borrow_global_mut<State>(@androcksys_framework);
        let round = vector::borrow_mut<Round>(&mut state.rounds, round_id);
		check_balance(signer::address_of(player), coin::value<AptosCoin>(&round.pool));

		let red = &mut round.red;
		let blue = &mut round.blue;

		assert!(*&round.winner == @0x0, error::unavailable(EROUND_HAS_ENDED));

		if(*red == @0x0) {
			*red = signer::address_of(player);
		} else {
			*blue = signer::address_of(player);
		};

		let coins = coin::withdraw<AptosCoin>(player, coin::value<AptosCoin>(&round.pool));
		coin::merge<AptosCoin>(&mut round.pool, coins);

		event::emit(EnterRound {
			id: round_id,
			player: signer::address_of(player)
		});

		select_winner(round_id);
    }

	#[randomness]
    public(friend) entry fun select_winner(round_id: u64) acquires State {
        let state = borrow_global_mut<State>(@androcksys_framework);
        let round = vector::borrow_mut<Round>(&mut state.rounds, round_id);

        let random_number = randomness::u8_integer();

        *&mut round.winner = if(random_number % 2 == 0) *&round.blue else *&round.red;

		let owner_fee = coin::value<AptosCoin>(&round.pool) * OWNER_FEE / 100;
		let owner_coins = coin::extract<AptosCoin>(&mut round.pool, owner_fee);
		
		let winning_amount = coin::value<AptosCoin>(&round.pool);
		let winning_coins = coin::extract_all<AptosCoin>(&mut round.pool);

		coin::deposit<AptosCoin>(@androcksys_framework, owner_coins);
        coin::deposit<AptosCoin>(*&round.winner, winning_coins);

        event::emit(EndRound {
			id: round_id,
			winner: *&round.winner,
			winning_amount
		});
    }

    public entry fun close_round(player: &signer, round_id: u64) acquires State {
        let state = borrow_global_mut<State>(@androcksys_framework);
        let round = vector::borrow_mut<Round>(&mut state.rounds, round_id);

		assert!(*&round.winner == @0x0, error::unavailable(EROUND_HAS_ENDED));

		*&mut round.winner = signer::address_of(player);
		let coins = coin::extract_all<AptosCoin>(&mut round.pool);
        coin::deposit<AptosCoin>(signer::address_of(player), coins);

        event::emit(CloseRound {
			id: round_id
		});
    }

    fun check_balance(account: address, value: u64) {
        let balance = coin::balance<AptosCoin>(account);
		assert!(balance >= value, error::aborted(ELOW_BALANCE));
    }

    #[view]
    public fun get_round_id(): u64 acquires State {
        let rounds = &borrow_global<State>(@androcksys_framework).rounds;
        vector::length(rounds) - 1
    }

    #[view]
    public fun get_round_winner(round_id: u64): address acquires State {
        let rounds = &borrow_global<State>(@androcksys_framework).rounds;
        assert!(vector::length(rounds) >= round_id, error::out_of_range(EWRONG_ROUND_ID));

        let round = vector::borrow<Round>(rounds, round_id);
		*&round.winner
    }

	#[view]
	public fun get_players(round_id: u64): (address, address) acquires State {
		let rounds = &borrow_global<State>(@androcksys_framework).rounds;
        assert!(vector::length(rounds) >= round_id, error::out_of_range(EWRONG_ROUND_ID));

		let round = vector::borrow<Round>(rounds, round_id);
		(*&round.red, *&round.blue)
	}

	#[test_only]
	use aptos_framework::aptos_coin;
	#[test_only]
	use aptos_framework::coin::{ MintCapability };
	#[test_only]
	use aptos_framework::aptos_account;

	#[test_only]
	fun init_for_test(owner: &signer, framework: &signer): MintCapability<AptosCoin> {
		timestamp::set_time_has_started_for_testing(framework);
		randomness::initialize_for_testing(framework);

		let (burn, mint) = aptos_coin::initialize_for_test(framework);
		coin::destroy_burn_cap(burn);

		init_module(owner);
		mint
	}

	#[test(owner = @androcksys_framework, framework = @0x1, player = @0x123)]
	fun can_create_round_with_min_bet(owner: &signer, framework: &signer, player: &signer) acquires State {
		let mint = init_for_test(owner, framework);
		aptos_account::create_account(signer::address_of(player));
		let coins = coin::mint<AptosCoin>(MIN_BET, &mint);
		coin::deposit<AptosCoin>(signer::address_of(player), coins);

		create_round(player, MIN_BET, true);

		assert!(get_round_id() == 0, 0);

		let (red, blue) = get_players(0);
		assert!(red == signer::address_of(player), 0);
		assert!(blue == @0x0, 0);

		let rounds = &borrow_global<State>(@androcksys_framework).rounds;
		let round = vector::borrow<Round>(rounds, 0);

		assert!(coin::value<AptosCoin>(&round.pool) == MIN_BET, 0);
		assert!(coin::balance<AptosCoin>(signer::address_of(player)) == 0, 0);

		coin::destroy_mint_cap<AptosCoin>(mint);
	}

	#[test(owner = @androcksys_framework, framework = @0x1, player1 = @0x123, player2 = @0x124)]
	fun can_enter_round(owner: &signer, framework: &signer, player1: &signer, player2: &signer) acquires State {
		let mint = init_for_test(owner, framework);

		aptos_account::create_account(signer::address_of(player1));
		aptos_account::create_account(signer::address_of(player2));
		aptos_account::create_account(@androcksys_framework);

		let coins = coin::mint<AptosCoin>(MIN_BET, &mint);
		coin::deposit<AptosCoin>(signer::address_of(player1), coins);

		let coins = coin::mint<AptosCoin>(MIN_BET, &mint);
		coin::deposit<AptosCoin>(signer::address_of(player2), coins);

		create_round(player1, MIN_BET, true);
		enter_round(player2, 0);

		let (_red, blue) = get_players(0);
		assert!(blue == signer::address_of(player2), 0);
		let winner = get_round_winner(0);
		assert!(winner != @0x0, 0);

		let owner_fee = MIN_BET * 2 / 10;
		assert!(coin::balance<AptosCoin>(winner) == MIN_BET * 2 - owner_fee, 0);
		assert!(coin::balance<AptosCoin>(@androcksys_framework) == owner_fee, 0);

		coin::destroy_mint_cap<AptosCoin>(mint);
	}

	#[test(owner = @androcksys_framework, framework = @0x1, player = @0x123)]
	fun can_close_round(owner: &signer, framework: &signer, player: &signer) acquires State {
		let mint = init_for_test(owner, framework);

		aptos_account::create_account(signer::address_of(player));
		let coins = coin::mint<AptosCoin>(MIN_BET, &mint);
		coin::deposit<AptosCoin>(signer::address_of(player), coins);

		create_round(player, MIN_BET, true);
		close_round(player, 0);

		assert!(coin::balance<AptosCoin>(signer::address_of(player)) == MIN_BET, 0);

		coin::destroy_mint_cap<AptosCoin>(mint);
	}
}