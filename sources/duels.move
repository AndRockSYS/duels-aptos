module androcksys_framework::duels {
    use std::signer;
    use std::vector;
    use std::error;

    use aptos_framework::timestamp;
    use aptos_framework::event;

    use aptos_framework::randomness;

    use aptos_framework::aptos_coin::{AptosCoin};
    use aptos_framework::coin::{Self, Coin};

    const EBetIsTooSmall: u64 = 001;
    const ELowBalance: u64 = 002;
    const ERoundIsFull: u64 = 003;
    const ERoundHasEnded: u64 = 004;
    const EIncorrectRoundId: u64 = 005;

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
        assert!(value >= MIN_BET, error::invalid_argument(EBetIsTooSmall));
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

    public entry fun enter_round(player: &signer, round_id: u64) acquires State {
        let state = borrow_global_mut<State>(@androcksys_framework);
        let round = vector::borrow_mut<Round>(&mut state.rounds, round_id);
		check_balance(signer::address_of(player), coin::value<AptosCoin>(&round.pool));

		let red = &mut round.red;
		let blue = &mut round.blue;

		assert!(*&round.winner == @0x0, error::unavailable(ERoundHasEnded));
		assert!(*red == @0x0 || *blue == @0x0, error::unavailable(ERoundIsFull));

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
    }

    public entry fun close_round(player: &signer, round_id: u64) acquires State {
        let state = borrow_global_mut<State>(@androcksys_framework);

        let round = vector::borrow_mut<Round>(&mut state.rounds, round_id);

		assert!(*&round.winner == @0x0, error::unavailable(ERoundHasEnded));
		assert!(*&round.red == @0x0 || *&round.blue == @0x0, error::unavailable(ERoundIsFull));

		let coins = coin::extract_all<AptosCoin>(&mut round.pool);
        coin::deposit<AptosCoin>(signer::address_of(player), coins);

        event::emit(CloseRound {
			id: round_id
		});
    }

	#[lint::allow_unsafe_randomness]
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

    fun check_balance(account: address, value: u64) {
        let balance = coin::balance<AptosCoin>(account);
		assert!(balance >= value, error::aborted(ELowBalance));
    }

    #[view]
    public fun get_round_id(): u64 acquires State {
        let rounds = &borrow_global<State>(@androcksys_framework).rounds;
        vector::length(rounds) - 1
    }

    #[view]
    public fun get_round_winner(round_id: u64): address acquires State {
        let rounds = &borrow_global<State>(@androcksys_framework).rounds;
        assert!(vector::length(rounds) >= round_id, error::out_of_range(EIncorrectRoundId));

        let round = vector::borrow<Round>(rounds, round_id);
		*&round.winner
    }

	#[view]
	public fun get_players(round_id: u64): (address, address) acquires State {
		let rounds = &borrow_global<State>(@androcksys_framework).rounds;
        assert!(vector::length(rounds) >= round_id, error::out_of_range(EIncorrectRoundId));

		let round = vector::borrow<Round>(rounds, round_id);
		(*&round.red, *&round.blue)
	}
}