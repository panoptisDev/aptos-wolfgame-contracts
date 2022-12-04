module woolf_deployer::risky_game {
    use std::error;
    use std::signer;
    use std::vector;

    use aptos_framework::event;
    use aptos_framework::account;

    use woolf_deployer::wool_pouch;
    use woolf_deployer::random;
    use woolf_deployer::traits;
    use woolf_deployer::barn;
    use aptos_std::table::Table;
    use aptos_std::table;
    use std::string;
    use woolf_deployer::utf8_utils;
    use woolf_deployer::token_helper;
    use woolf_deployer::config;
    use aptos_token::token::TokenId;
    use aptos_framework::timestamp;

    //
    // Constants
    //
    const TOTAL_GEN0_GEN1: u64 = 13809;
    const STATE_UNDECIDED: u8 = 0;
    const STATE_OPTED_IN: u8 = 1;
    const STATE_EXECUTED: u8 = 2;

    const MAXIMUM_WOOL: u64 = 2400000000 * 100000000;
    // FIXME fix those value
    const TOTAL_CLAIMED_WOOL: u64 = 0;
    const TOTAL_STAKED_EARNINGS: u64 = 0;
    const TOTAL_UNSTAKED_EARNINGS: u64 = 0;
    const TOTAL_ALPHA: u64 = 9901;

    const MAX_ALPHA: u64 = 8;
    const ONE_DAY_IN_SECONDS: u64 = 86400;

    //
    // Errors
    //
    const EPAUSED: u64 = 1;
    const EONLY_ORIGINALS_CAN_PLAY_RISKY_GAME: u64 = 2;
    const EWOLVES_CANT_PLAY_IT_SAFE: u64 = 3;
    const ECANT_CLAIM_TWICE: u64 = 4;
    const EOPPORTUNITY_PASSED: u64 = 5;
    const ESHOULD_BE_SHEEP: u64 = 6;
    const ENOT_TOKEN_OWNER: u64 = 7;

    struct SafeClaim has store, drop {
        recipient: address,
        token_ids: vector<u64>,
        amount: u64
    }

    struct OptForRisk has store, drop {
        owner: address,
        token_ids: vector<u64>,
    }

    struct RiskyClaim has store, drop {
        recipient: address,
        token_ids: vector<u64>,
        winners: vector<bool>,
        amount: u64,
    }

    struct WolfClaim has store, drop {
        recipient: address,
        token_ids: vector<u64>,
        amount: u64
    }

    struct Events has key {
        safe_claim_events: event::EventHandle<SafeClaim>,
        opt_for_risk_events: event::EventHandle<OptForRisk>,
        risky_claim_events: event::EventHandle<RiskyClaim>,
        wolf_claim_events: event::EventHandle<WolfClaim>,
    }

    struct Data has key {
        opt_in_enabled: bool,
        paused: bool,
        safe_game_wool: u64,
        risk_game_wool: u64,
        total_risk_takers: u64,
        token_states: Table<u64, u8>,
    }

    public(friend) fun initialize(framework: &signer) {
        move_to(framework, Data {
            opt_in_enabled: true,
            paused: true,
            safe_game_wool: 0,
            risk_game_wool: 0, // FIXME
            total_risk_takers: 0,
            token_states: table::new(),
        });

        move_to(framework, Events {
            safe_claim_events: account::new_event_handle<SafeClaim>(framework),
            opt_for_risk_events: account::new_event_handle<OptForRisk>(framework),
            risky_claim_events: account::new_event_handle<RiskyClaim>(framework),
            wolf_claim_events: account::new_event_handle<WolfClaim>(framework),
        })
    }

    fun assert_not_paused() acquires Data {
        let data = borrow_global<Data>(@woolf_deployer);
        assert!(&data.paused == &false, error::permission_denied(EPAUSED));
    }

    public entry fun set_paused(paused: bool) acquires Data {
        let data = borrow_global_mut<Data>(@woolf_deployer);
        data.paused = paused;
    }

    // opts into the No Risk option and claims WOOL Pouches
    public entry fun play_it_safe(
        player: &signer,
        token_ids: vector<u64>,
        separate_pouches: bool
    ) acquires Data, Events {
        assert_not_paused();
        let earned: u64 = 0;
        let i = 0;
        let temp: u64;
        let data = borrow_global_mut<Data>(@woolf_deployer);
        while (i < vector::length(&token_ids)) {
            let token_id = *vector::borrow(&token_ids, i);
            assert!(owner_of(token_id) == signer::address_of(player), error::permission_denied(ENOT_TOKEN_OWNER));
            assert!(token_id <= TOTAL_GEN0_GEN1, error::out_of_range(EONLY_ORIGINALS_CAN_PLAY_RISKY_GAME));
            assert!(is_sheep(token_id), error::invalid_state(ESHOULD_BE_SHEEP));
            assert!(get_token_state(data, token_id) == STATE_UNDECIDED, error::invalid_state(ECANT_CLAIM_TWICE));

            temp = get_wool_due(token_id);
            set_token_state(data, token_id, STATE_EXECUTED);
            if (separate_pouches) {
                wool_pouch::mint_internal(signer::address_of(player), temp * 4 / 5, 365 * 4); // charge 20% tax
            };
            earned = earned + temp;
            i = i + 1;
        };

        data.safe_game_wool = data.safe_game_wool + earned;
        if (!separate_pouches) {
            // charge 20% tax
            wool_pouch::mint_internal(signer::address_of(player), earned * 4 / 5, 365 * 4);
        };
        event::emit_event<SafeClaim>(
            &mut borrow_global_mut<Events>(@woolf_deployer).safe_claim_events,
            SafeClaim {
                recipient: signer::address_of(player), token_ids, amount: earned
            },
        );
    }

    // opts into the Yes Risk option
    public entry fun take_a_risk(
        player: &signer,
        token_ids: vector<u64>
    ) acquires Data, Events {
        assert_not_paused();
        let data = borrow_global_mut<Data>(@woolf_deployer);
        assert!(data.opt_in_enabled, error::permission_denied(EOPPORTUNITY_PASSED));

        let i = 0;
        while (i < vector::length(&token_ids)) {
            let token_id = *vector::borrow(&token_ids, i);
            assert!(owner_of(token_id) == signer::address_of(player), error::permission_denied(ENOT_TOKEN_OWNER));
            assert!(token_id <= TOTAL_GEN0_GEN1, error::out_of_range(EONLY_ORIGINALS_CAN_PLAY_RISKY_GAME));
            assert!(is_sheep(token_id), error::invalid_state(ESHOULD_BE_SHEEP));
            assert!(get_token_state(data, token_id) == STATE_UNDECIDED, error::invalid_state(ECANT_CLAIM_TWICE));

            set_token_state(data, token_id, STATE_OPTED_IN);
            data.risk_game_wool = data.risk_game_wool + get_wool_due(token_id);
            data.total_risk_takers = data.total_risk_takers + 1;
            i = i + 1;
        };
        event::emit_event<OptForRisk>(
            &mut borrow_global_mut<Events>(@woolf_deployer).opt_for_risk_events,
            OptForRisk {
                owner: signer::address_of(player), token_ids
            },
        );
    }

    // reveals the results of Yes Risk for Sheep and gives WOOL Pouches
    public entry fun execute_risk(
        player: &signer,
        token_ids: vector<u64>,
        separate_pouches: bool
    ) acquires Data, Events {
        assert_not_paused();
        let data = borrow_global_mut<Data>(@woolf_deployer);
        let earned = 0;
        let i = 0;
        let winners = vector::empty<bool>();
        while (i < vector::length(&token_ids)) {
            let token_id = *vector::borrow(&token_ids, i);
            assert!(owner_of(token_id) == signer::address_of(player), error::permission_denied(ENOT_TOKEN_OWNER));
            assert!(token_id <= TOTAL_GEN0_GEN1, error::out_of_range(EONLY_ORIGINALS_CAN_PLAY_RISKY_GAME));
            assert!(is_sheep(token_id), error::invalid_state(ESHOULD_BE_SHEEP));
            assert!(get_token_state(data, token_id) == STATE_UNDECIDED, error::invalid_state(ECANT_CLAIM_TWICE));
            set_token_state(data, token_id, STATE_EXECUTED);
            if (!did_sheep_defeat_wolves(token_id)) {
                vector::push_back(&mut winners, false);
                continue
            };
            if (separate_pouches) {
                wool_pouch::mint_internal(
                    signer::address_of(player),
                    data.risk_game_wool / data.total_risk_takers,
                    365 * 4
                );
            };
            earned = earned + data.risk_game_wool / data.total_risk_takers;
            vector::push_back(&mut winners, true);
            i = i + 1;
        };
        if (!separate_pouches && earned > 0) {
            wool_pouch::mint_internal(signer::address_of(player), earned, 365 * 4);
        };
        event::emit_event<RiskyClaim>(
            &mut borrow_global_mut<Events>(@woolf_deployer).risky_claim_events,
            RiskyClaim {
                recipient: signer::address_of(player),
                token_ids,
                winners,
                amount: earned,
            },
        );
    }

    // claims the taxed and Yes Risk earnings for wolves in WOOL Pouches
    public entry fun claim_wolf_earnings(
        player: &signer,
        token_ids: vector<u64>,
        separate_pouches: bool
    ) acquires Data, Events {
        assert_not_paused();
        let data = borrow_global_mut<Data>(@woolf_deployer);
        let i = 0;
        let temp;
        let earned = 0;
        let alpha: u64;
        // amount in taxes is 20% of remainder after unclaimed wool from v1 and risk game
        let taxes = (MAXIMUM_WOOL - data.risk_game_wool - TOTAL_CLAIMED_WOOL) / 5;
        // if there are no sheep playing risk game, wolves win the whole pot
        let total_wolf_earnings = taxes + data.risk_game_wool / (if (data.total_risk_takers > 0) 2 else 1);
        while (i < vector::length(&token_ids)) {
            let token_id = *vector::borrow(&token_ids, i);
            assert!(owner_of(token_id) == signer::address_of(player), error::permission_denied(ENOT_TOKEN_OWNER));
            assert!(token_id <= TOTAL_GEN0_GEN1, error::out_of_range(EONLY_ORIGINALS_CAN_PLAY_RISKY_GAME));
            assert!(is_sheep(token_id), error::invalid_state(ESHOULD_BE_SHEEP));
            assert!(get_token_state(data, token_id) == STATE_UNDECIDED, error::invalid_state(ECANT_CLAIM_TWICE));

            set_token_state(data, token_id, STATE_EXECUTED);
            alpha = (alphaForWolf(token_id) as u64);
            temp = total_wolf_earnings * alpha / TOTAL_ALPHA;
            earned = earned + temp;
            if (separate_pouches) {
                wool_pouch::mint_internal(signer::address_of(player), temp, 365 * 4);
            };
            i = i + 1;
        };

        if (!separate_pouches && earned > 0) {
            // charge 20% tax
            wool_pouch::mint_internal(signer::address_of(player), earned, 365 * 4);
        };
        event::emit_event<WolfClaim>(
            &mut borrow_global_mut<Events>(@woolf_deployer).wolf_claim_events,
            WolfClaim {
                recipient: signer::address_of(player), token_ids, amount: earned
            },
        );
    }

    fun get_token_id(token_index: u64): TokenId {
        let name = string::utf8(b"");
        if (is_sheep(token_index)) {
            string::append_utf8(&mut name, b"Sheep #");
        } else {
            string::append_utf8(&mut name, b"Wolf #");
        };
        string::append(&mut name, utf8_utils::to_string(token_index));

        let token_id = token_helper::create_token_id(
            config::collection_name(),
            name,
            1,
        );
        token_id
    }

    fun owner_of(_token_index: u64): address {
        // FIXME
        @0x0
    }

    fun is_sheep(token_index: u64): bool {
        let (sheep, _, _, _, _, _, _, _, _, _) = traits::get_index_traits(token_index);
        sheep
    }

    fun did_sheep_defeat_wolves(_token_index: u64): bool {
        // 50/50
        random::rand_u64_range_no_sender(0, 2) == 0
    }

    fun alphaForWolf(token_index: u64): u8 {
        let (_, _, _, _, _, _, _, _, _, alpha) = traits::get_index_traits(token_index);
        barn::max_alpha() - alpha
    }

    // gets the WOOL due for a Sheep based on their state before Barn v1 was paused
    fun get_wool_due(token_index: u64): u64 {
        // TODO
        let token_id = get_token_id(token_index);
        if (barn::sheep_in_barn(token_id)){
            let value = barn::get_stake_value(token_id);
            return (timestamp::now_seconds() - value) * 10000 / ONE_DAY_IN_SECONDS
        } else {
            return 0
        }
    }

    fun set_token_state(data: &mut Data, token_index: u64, state: u8) {
        table::upsert(&mut data.token_states, token_index, state);
    }

    fun get_token_state(data: &Data, token_index: u64): u8 {
        *table::borrow(&data.token_states, token_index)
    }
}
