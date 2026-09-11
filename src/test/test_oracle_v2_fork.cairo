/// Fork tests for `oracle_v2`, pinned to mainnet block 14_500_000 (§11 of `Oracle_Redesign.md`).
///
/// These cover what the mock suite structurally cannot: that the interfaces in `src/vendor/` match the
/// **deployed** ABIs, that every route §4.2 plans actually resolves against its real source, and that
/// the parameters the document recommends hold against real data rather than against fixtures chosen
/// to satisfy them.
///
/// The asset list is not guessed. It is the 24 assets the deployed oracle has ever configured, read
/// off its `SetOracleConfig` events, which is the authoritative definition of "every planned route".
///
/// Every value asserted below was read off mainnet at this block, so the tests are deterministic.
/// Observed figures are recorded next to the band they are asserted within; where a band is loose it
/// is loose on purpose, so that the test states a tolerance rather than a snapshot.
#[cfg(test)]
mod TestOracleV2Fork {
    use alexandria_math::i257::I257Trait;
    use core::num::traits::Zero;
    use snforge_std::{CheatSpan, cheat_caller_address, start_cheat_block_timestamp_global};
    use starknet::{ContractAddress, contract_address_const, get_block_timestamp};
    use vesu::data_model::{Amount, AmountDenomination, LiquidatePositionParams, ModifyPositionParams};
    use vesu::math::pow_10;
    use vesu::oracle::{
        IOracleDispatcher, IOracleDispatcherTrait, IPragmaOracleDispatcher, IPragmaOracleDispatcherTrait,
    };
    use vesu::oracle_v2::{
        ChainlinkConfig, EkuboConfig, IOracleV2Dispatcher, IOracleV2DispatcherTrait, MIN_TWAP_WINDOW, PriceRouteKind,
        ScaledConfig,
    };
    use vesu::pool::{IPoolDispatcher, IPoolDispatcherTrait};
    use vesu::test::mock_oracle_v2::{IMockChainlinkFeedDispatcher, IMockChainlinkFeedDispatcherTrait};
    use vesu::test::setup_v2::deploy_with_args;
    use vesu::units::{PERCENT, SCALE};
    use vesu::vendor::chainlink::{IChainlinkAggregatorDispatcher, IChainlinkAggregatorDispatcherTrait};
    use vesu::vendor::ekubo::{IEkuboOracleDispatcher, IEkuboOracleDispatcherTrait};
    use vesu::vendor::erc4626::{IERC4626Dispatcher, IERC4626DispatcherTrait};

    /// timestamp of the pinned block
    const BLOCK_TIMESTAMP: u64 = 1788775475;
    const TIMELOCK: u64 = 86400;
    const BPS: u256 = 100_000_000_000_000; // 1e14 == 1 basis point in SCALE

    /// §6.2 recommendations
    const VOLATILE_STALENESS: u64 = 3600;
    const STABLE_STALENESS: u64 = 90000;

    /// §6.3 / §11.5 — calibrated in `test_fork_cone_slope_covers_observed_wrapper_growth` below.
    const MAX_GROWTH_PER_SECOND: u128 = 10_000_000_000;
    const MAX_RATE: u128 = 2_000_000_000_000_000_000;
    const MIN_RATE_RATIO: u128 = 990_000_000_000_000_000;

    // --- §4.1 feeds ---------------------------------------------------------------------------
    fn btc_usd_feed() -> ContractAddress {
        contract_address_const::<0x05a4930401bbb1d643ca501640e218fec253b33326f47d139bd025c62a1fbc7f>()
    }
    fn eth_usd_feed() -> ContractAddress {
        contract_address_const::<0x06b2ef9b416ad0f996b2a8ac0dd771b1788196f51c96f5b000df2e47ac756d26>()
    }
    fn strk_usd_feed() -> ContractAddress {
        contract_address_const::<0x076a0254cdadb59b86da3b5960bf8d73779cac88edc5ae587cab3cedf03226ec>()
    }
    fn usdc_usd_feed() -> ContractAddress {
        contract_address_const::<0x072495dbb867dd3c6373820694008f8a8bff7b41f7f7112245d687858b243470>()
    }
    fn usdt_usd_feed() -> ContractAddress {
        contract_address_const::<0x01cafc789a9b48f816fe0969c22667ea2d669e56274c806fc83a85215d42e988>()
    }
    /// WBTC has its own feed, so pricing it at BTC parity is a choice rather than a necessity
    fn wbtc_usd_feed() -> ContractAddress {
        contract_address_const::<0x06275040a2913e2fe1a20bead3feb40694920a7fea98e956b042e082b9e1adad>()
    }
    /// The only ETH-quoted feed, and the only one that is not 8 decimal. Both facts are load-bearing:
    /// it is the sole live instance of the sec 3.3 composed Chainlink route, and the sole live check
    /// that `feed_decimals` is really read from the feed rather than assumed.
    fn wsteth_eth_feed() -> ContractAddress {
        contract_address_const::<0x07ba92ee505a967f56253a5a51d8249c0515577fa9d1dea7f24e233ae3395184>()
    }

    // --- directly fed assets (§4.2) -------------------------------------------------------------
    fn eth() -> ContractAddress {
        contract_address_const::<0x049d36570d4e46f48e99674bd3fcc84644ddd6b96f7c741b1562b82f9e004dc7>()
    }
    /// the two USDC addresses the live oracle lists, both on the `USDC/USD` key — §4.2's "USDC" and
    /// "USDC.e" rows. Both are 6 decimal and report the symbol `USDC`, so they are distinguished here
    /// by address rather than by metadata.
    fn usdc() -> ContractAddress {
        contract_address_const::<0x053c91253bc9682c04929ca02ed00b3e423f6710d2ee7e0d5ebb06f3ecf368a8>()
    }
    fn usdc_second() -> ContractAddress {
        contract_address_const::<0x033068f6539f8e6e6b131e6b2b814e6c34a5224bc66947c47dab9dfee93b35fb>()
    }
    fn usdt() -> ContractAddress {
        contract_address_const::<0x068f5c6a61780768455de69077e07e89787839bf8166decfbf92b645209c0fb8>()
    }
    fn strk() -> ContractAddress {
        contract_address_const::<0x04718f5a0fc34cc1af16a1cdee98ffb20c31f5cd61d6ab07201858f4287c938d>()
    }

    // --- BTC wrappers priced at parity (§4.2, §4.4) ---------------------------------------------
    fn wbtc() -> ContractAddress {
        contract_address_const::<0x03fe2b97c1fd336e750087d68b9b867997fd64a2661ff3ca5a7c771641e8e7ac>()
    }
    fn tbtc() -> ContractAddress {
        contract_address_const::<0x04daa17763b286d1e59b97c283c0b8c949994c361e426a28f743c67bdfe9a32f>()
    }
    fn lbtc() -> ContractAddress {
        contract_address_const::<0x036834a40984312f7f7de8d31e3f6305b325389eaeea5b1c0664b2fb936461a4>()
    }
    fn solvbtc() -> ContractAddress {
        contract_address_const::<0x0593e034dda23eea82d2ba9a30960ed42cf4a01502cc2351dc9b9881f9931a68>()
    }
    fn strkbtc() -> ContractAddress {
        contract_address_const::<0x0787150e306e6eae6e3f79dea881770e8bbff2c1b8eb490f969669ee945b3135>()
    }
    fn unibtc() -> ContractAddress {
        contract_address_const::<0x023a312ece4a275e38c9fc169e3be7b5613a0cb55fe1bece4422b09a88434573>()
    }
    fn ybtc_b() -> ContractAddress {
        contract_address_const::<0x02cab84694e1be6af2ce65b1ae28a76009e8ec99ec4bc17047386abf20cbb688>()
    }
    /// Listed on the deployed oracle against `BTC/USD` but absent from §4.2's table, and the only
    /// 10 decimal asset in the set.
    fn ebtc() -> ContractAddress {
        contract_address_const::<0x02342f9d4eb0d47cb3f9de41fa1dbac6d154824d63e66b363eeb256683fea3bc>()
    }

    // --- Endur wrappers (§4.3) -------------------------------------------------------------------
    fn xstrk() -> ContractAddress {
        contract_address_const::<0x028d709c875c0ceac3dce7065bec5328186dc89fe254527084d1689910954b0a>()
    }
    fn xwbtc() -> ContractAddress {
        contract_address_const::<0x06a567e68c805323525fe1649adb80b03cddf92c23d2629a6779f54192dffc13>()
    }
    fn xlbtc() -> ContractAddress {
        contract_address_const::<0x07dd3c80de9fcc5545f0cb83678826819c79619ed7992cc06ff81fc67cd2efe0>()
    }
    fn xsbtc() -> ContractAddress {
        contract_address_const::<0x0580f3dc564a7b82f21d40d404b3842d490ae7205e6ac07b1b7af2b4a5183dc9>()
    }
    fn xtbtc() -> ContractAddress {
        contract_address_const::<0x043a35c1425a0125ef8c171f1a75c6f31ef8648edcc8324b55ce1917db3f9b91>()
    }
    fn xstrkbtc() -> ContractAddress {
        contract_address_const::<0x047751b3532fabca89b0f2e35ca1cb45e5a7b11d5e3d3663dfa1f4406b45fd88>()
    }

    // --- §8 assets with no acceptable route, which stay on the legacy Pragma kind -----------------
    fn wsteth() -> ContractAddress {
        contract_address_const::<0x0057912720381af14b0e5c87aa4718ed5e527eab60b3801ebf702ab09139e38b>()
    }
    fn susn() -> ContractAddress {
        contract_address_const::<0x02411565ef1a14decfbe83d2e987cced918cd752508a3d9c55deb67148d14d17>()
    }
    fn mre7btc() -> ContractAddress {
        contract_address_const::<0x04e4fb1a9ca7e84bae609b9dc0078ad7719e49187ae7e425bb47d131710eddac>()
    }
    fn mre7yield() -> ContractAddress {
        contract_address_const::<0x04be8945e61dc3e19ebadd1579a6bd53b262f51ba89e6f8b0c4bc9a7e3c633fc>()
    }

    // --- §5 / Appendix A --------------------------------------------------------------------------
    fn ekubo() -> ContractAddress {
        contract_address_const::<0x075afe6402ad5a5c20dd25e10ec3b3986acaa647b77e4ae24b0cbc9a54a27a87>()
    }
    fn ekubo_oracle_extension() -> ContractAddress {
        contract_address_const::<0x005e470ff654d834983a46b8f29dfa99963d5044b993cb7b9c92243a69dab38f>()
    }
    fn pragma_oracle() -> ContractAddress {
        contract_address_const::<0x02a85bd616f912537c50a49a4076db02c00b29b2cdc8a197ce92ed1837fa875b>()
    }
    /// the currently deployed V2 oracle, used as the shadow-parity reference
    fn live_oracle() -> IPragmaOracleDispatcher {
        IPragmaOracleDispatcher {
            contract_address: contract_address_const::<
                0x00fe4bfb1b353ba51eb34dff963017f94af5a5cf8bdf3dfc191c504657f3c05,
            >(),
        }
    }
    fn live_price() -> IOracleDispatcher {
        IOracleDispatcher { contract_address: live_oracle().contract_address }
    }

    /// every asset the deployed oracle has configured, from its `SetOracleConfig` events
    fn all_listed_assets() -> Array<ContractAddress> {
        array![
            eth(),
            usdc(),
            usdc_second(),
            usdt(),
            strk(),
            wbtc(),
            tbtc(),
            lbtc(),
            solvbtc(),
            strkbtc(),
            unibtc(),
            ybtc_b(),
            ebtc(),
            xstrk(),
            xwbtc(),
            xlbtc(),
            xsbtc(),
            xtbtc(),
            xstrkbtc(),
            ekubo(),
            wsteth(),
            susn(),
            mre7btc(),
            mre7yield(),
        ]
    }

    fn btc_parity_assets() -> Array<ContractAddress> {
        array![wbtc(), tbtc(), lbtc(), solvbtc(), strkbtc(), unibtc(), ybtc_b(), ebtc()]
    }

    // --- the deployed Prime pool and real positions in it ---------------------------------------
    /// Vesu V2 `Prime`, the most active pool on mainnet. Already pointed at the deployed V2 oracle.
    fn prime() -> IPoolDispatcher {
        IPoolDispatcher {
            contract_address: contract_address_const::<
                0x451fe483d5921a2919ddd81d0de6696669bccdacd859f72a4fba7656b97c3b5,
            >(),
        }
    }
    /// only the curator may call `set_oracle`
    fn prime_curator() -> ContractAddress {
        contract_address_const::<0x5028372e584acb5e14de6737c6b46dd9319508ba584ba8c651ef848bedd6a7d>()
    }
    /// a real wstETH-collateral / ETH-debt position, 80.5% LTV at the fork block
    fn wsteth_eth_user() -> ContractAddress {
        contract_address_const::<0x17846b313cb69e95fc2e41b7be3d046edc40a33844c23fdd67c576abc706f0b>()
    }
    /// a real xSTRK / STRK position, 83.0% LTV — close enough to its limit to be worth watching
    fn xstrk_strk_user() -> ContractAddress {
        contract_address_const::<0x7f487c538d0de7940eb0fe7a14f700cf7ef6408a27802cdf5aa0cd1c3c638a3>()
    }
    /// a real xWBTC / WBTC position, 70.8% LTV
    fn xwbtc_wbtc_user() -> ContractAddress {
        contract_address_const::<0x10139a7f261cf2cca7d8ef889d0be707853742fe6be0db4f856145ca9592587>()
    }
    /// A real wstETH / USDT position, 45.5% LTV. Used for the liveness tests because the composite's
    /// quote leg (ETH) is *not* the debt asset, so a single leg can be invalidated on its own.
    fn wsteth_usdt_user() -> ContractAddress {
        contract_address_const::<0x0819310a3bbafb23a122507bc756c78155079d5c5f2d774eda94bf63d3b22ba>()
    }
    /// a real xSTRK / USDT position, 19.9% LTV — same reason, for the `Scaled` kind
    fn xstrk_usdt_user() -> ContractAddress {
        contract_address_const::<0x6b81a6b7b7e14c78a373a1c21ac0e69320057365a7cc55ac97a4146574d8819>()
    }

    fn owner() -> ContractAddress {
        contract_address_const::<'owner'>()
    }
    fn manager() -> ContractAddress {
        contract_address_const::<'manager'>()
    }

    #[derive(Copy, Drop)]
    struct Env {
        oracle: IOracleV2Dispatcher,
        price_oracle: IOracleDispatcher,
    }

    fn setup() -> Env {
        let address = deploy_with_args(
            "OracleV2", array![owner().into(), manager().into(), pragma_oracle().into(), TIMELOCK.into()],
        );
        Env {
            oracle: IOracleV2Dispatcher { contract_address: address },
            price_oracle: IOracleDispatcher { contract_address: address },
        }
    }

    fn add_chainlink(env: Env, asset: ContractAddress, feed: ContractAddress, max_staleness: u64) {
        cheat_caller_address(env.oracle.contract_address, manager(), CheatSpan::TargetCalls(1));
        env
            .oracle
            .add_chainlink_asset(
                asset, ChainlinkConfig { feed, feed_decimals: 0, max_staleness, quote_asset: Zero::zero() },
            );
    }

    fn scaled_config(base_asset: ContractAddress, wrapper: ContractAddress) -> ScaledConfig {
        ScaledConfig {
            base_asset,
            wrapper,
            share_decimals: 0,
            underlying_decimals: 0,
            ref_rate: 0,
            ref_timestamp: 0,
            max_growth_per_second: MAX_GROWTH_PER_SECOND,
            min_rate_ratio: MIN_RATE_RATIO,
            max_rate: MAX_RATE,
        }
    }

    fn add_scaled(env: Env, asset: ContractAddress, base_asset: ContractAddress) {
        cheat_caller_address(env.oracle.contract_address, manager(), CheatSpan::TargetCalls(1));
        env.oracle.add_scaled_asset(asset, scaled_config(base_asset, asset));
    }

    fn ekubo_config(window: u64) -> EkuboConfig {
        EkuboConfig {
            oracle_extension: ekubo_oracle_extension(),
            quote_asset: eth(),
            base_decimals: 0,
            quote_decimals: 0,
            window,
            max_spot_deviation: 10 * PERCENT.try_into().unwrap(),
        }
    }

    fn add_ekubo(env: Env, window: u64) {
        cheat_caller_address(env.oracle.contract_address, manager(), CheatSpan::TargetCalls(1));
        env.oracle.add_ekubo_asset(ekubo(), ekubo_config(window));
    }

    /// configures every §4.2 route on one router: direct feeds, BTC parity, the six Endur wrappers,
    /// EKUBO, and the §8 assets left on Pragma
    fn setup_all_routes(env: Env) {
        add_chainlink(env, eth(), eth_usd_feed(), VOLATILE_STALENESS);
        add_chainlink(env, strk(), strk_usd_feed(), VOLATILE_STALENESS);
        add_chainlink(env, usdc(), usdc_usd_feed(), STABLE_STALENESS);
        add_chainlink(env, usdc_second(), usdc_usd_feed(), STABLE_STALENESS);
        add_chainlink(env, usdt(), usdt_usd_feed(), STABLE_STALENESS);
        for asset in btc_parity_assets() {
            add_chainlink(env, asset, btc_usd_feed(), VOLATILE_STALENESS);
        }
        add_scaled(env, xstrk(), strk());
        add_scaled(env, xwbtc(), wbtc());
        add_scaled(env, xlbtc(), lbtc());
        add_scaled(env, xsbtc(), solvbtc());
        add_scaled(env, xtbtc(), tbtc());
        add_scaled(env, xstrkbtc(), strkbtc());
        add_ekubo(env, 3600);
        // sec 8's wstETH direction, now that the feed it was waiting on exists: an ETH-quoted
        // Chainlink feed composed over ETH/USD. The slow staleness bound is deliberate — see
        // `test_fork_wsteth_feed_needs_the_slow_staleness_bound`.
        cheat_caller_address(env.oracle.contract_address, manager(), CheatSpan::TargetCalls(1));
        env
            .oracle
            .add_chainlink_asset(
                wsteth(),
                ChainlinkConfig {
                    feed: wsteth_eth_feed(), feed_decimals: 0, max_staleness: STABLE_STALENESS, quote_asset: eth(),
                },
            );
        for asset in array![susn(), mre7btc(), mre7yield()] {
            cheat_caller_address(env.oracle.contract_address, manager(), CheatSpan::TargetCalls(1));
            env.oracle.add_pragma_asset(asset, live_oracle().oracle_config(asset));
        }
    }

    fn divergence_bps(actual: u256, expected: u256) -> u256 {
        assert!(expected != 0, "expected is zero");
        let delta = if actual > expected {
            actual - expected
        } else {
            expected - actual
        };
        delta * 10000 / expected
    }

    fn assert_within_bps(actual: u256, expected: u256, tolerance_bps: u256, message: ByteArray) {
        let observed = divergence_bps(actual, expected);
        assert!(
            observed <= tolerance_bps,
            "{}: {} vs {} ({} bps, allow {})",
            message,
            actual,
            expected,
            observed,
            tolerance_bps,
        );
    }

    fn assert_in_band(value: u256, low: u256, high: u256, message: ByteArray) {
        assert!(value >= low && value <= high, "{}: {} outside [{}, {}]", message, value, low, high);
    }

    // ------------------------------------------------------------------------------------------
    // §4.1 — the deployed feeds
    // ------------------------------------------------------------------------------------------

    /// §4.1 leaves the representation of `answer` as an open item ("confirm against the deployed proxy
    /// ABI before implementation"). The deployed aggregator declares
    /// `Round { round_id: felt252, answer: u128, block_num: u64, started_at: u64, updated_at: u64 }`,
    /// and `answer: u128` cannot encode a negative, so the vendor struct is exact and the
    /// negative-answer case does not arise. This reproduces the router's scaling from the individual
    /// fields, so any shift in the field order moves `answer` onto `block_num` or `round_id`.
    #[test]
    #[fork("OracleMainnet")]
    fn test_fork_chainlink_round_abi_matches_the_vendor_struct() {
        let env = setup();
        add_chainlink(env, eth(), eth_usd_feed(), VOLATILE_STALENESS);

        let feed = IChainlinkAggregatorDispatcher { contract_address: eth_usd_feed() };
        let round = feed.latest_round_data();
        assert!(feed.decimals() == 8, "every sec 4.1 feed is 8 decimal");
        assert!(env.oracle.chainlink_config(eth()).feed_decimals == 8, "decimals not derived from the live feed");

        let price = env.price_oracle.price(eth());
        assert!(price.is_valid, "the live ETH/USD feed must price");
        assert!(price.value == round.answer.into() * SCALE / pow_10(8), "field order or scaling mismatch");
        // `updated_at` must read as a timestamp, not as a block number or a round id
        assert_in_band(round.updated_at.into(), 1_700_000_000, BLOCK_TIMESTAMP.into(), "updated_at is not a timestamp");
    }

    /// Every feed a §4.2 route actually reads. DAI/USD and LINK/USD are deliberately excluded: they
    /// exist on mainnet and §4.1 tabulates them, but nothing routes to them, so asserting on them
    /// would be testing Chainlink rather than this router.
    ///
    /// The decimals assertion is deliberately not a blanket 8: WSTETH/ETH is 18. Assuming 8 across the
    /// set is exactly the mistake that deriving `feed_decimals` from the feed is meant to prevent.
    #[test]
    #[fork("OracleMainnet")]
    fn test_fork_every_routed_feed_answers_and_is_plausible() {
        for feed in array![
            btc_usd_feed(), eth_usd_feed(), strk_usd_feed(), usdc_usd_feed(), usdt_usd_feed(), wbtc_usd_feed(),
        ] {
            let dispatcher = IChainlinkAggregatorDispatcher { contract_address: feed };
            assert!(dispatcher.decimals() == 8, "a routed USD feed is no longer 8 decimal");
            let round = dispatcher.latest_round_data();
            assert!(round.answer != 0, "a routed feed answers zero");
            assert!(round.updated_at != 0, "a routed feed has an incomplete round");
            assert_in_band(
                round.updated_at.into(),
                1_700_000_000,
                BLOCK_TIMESTAMP.into(),
                "a routed feed timestamp is implausible",
            );
        }
        // the ETH-quoted feed answers on the same interface but carries its own decimals
        let wsteth_feed = IChainlinkAggregatorDispatcher { contract_address: wsteth_eth_feed() };
        assert!(wsteth_feed.decimals() == 18, "WSTETH/ETH is an 18 decimal feed");
        assert!(wsteth_feed.latest_round_data().answer != 0, "WSTETH/ETH answers zero");
    }

    // ------------------------------------------------------------------------------------------
    // §4.2 — every planned direct Chainlink route
    // ------------------------------------------------------------------------------------------

    #[test]
    #[fork("OracleMainnet")]
    fn test_fork_direct_feed_routes_all_price() {
        let env = setup();
        add_chainlink(env, eth(), eth_usd_feed(), VOLATILE_STALENESS);
        add_chainlink(env, strk(), strk_usd_feed(), VOLATILE_STALENESS);
        add_chainlink(env, usdc(), usdc_usd_feed(), STABLE_STALENESS);
        add_chainlink(env, usdc_second(), usdc_usd_feed(), STABLE_STALENESS);
        add_chainlink(env, usdt(), usdt_usd_feed(), STABLE_STALENESS);

        // ETH $2,485.72 and STRK $0.031047 at this block
        assert_in_band(env.price_oracle.price(eth()).value, 500 * SCALE, 20_000 * SCALE, "ETH/USD");
        assert_in_band(env.price_oracle.price(strk()).value, SCALE / 1000, SCALE, "STRK/USD");
        // the three stable legs must hold their peg within 2%
        for asset in array![usdc(), usdc_second(), usdt()] {
            assert_within_bps(env.price_oracle.price(asset).value, SCALE, 200, "stablecoin off peg");
        }
        // §4.2 routes both USDC addresses to the same feed, so they must price identically
        assert!(
            env.price_oracle.price(usdc()).value == env.price_oracle.price(usdc_second()).value,
            "USDC and USDC.e share a feed and must share a price",
        );
        for asset in array![eth(), strk(), usdc(), usdc_second(), usdt()] {
            assert!(env.price_oracle.price(asset).is_valid, "every direct feed route must be valid");
        }
    }

    /// §4.2 routes eight BTC wrappers to the single `BTC/USD` feed. The property that follows — and
    /// that §4.4 warns about — is that they become *exactly* price-invariant against each other, so a
    /// wrapper-vs-wrapper pair carries no depeg signal at all. It is asserted rather than described,
    /// because it is the thing a reviewer should see stated.
    ///
    /// It also spans 8, 10 and 18 decimal tokens, which pins that a direct Chainlink route is
    /// decimals-independent: the feed answers USD per whole token, so the asset's own decimals must
    /// not enter the price.
    #[test]
    #[fork("OracleMainnet")]
    fn test_fork_btc_wrappers_price_at_exact_parity_across_decimals() {
        let env = setup();
        for asset in btc_parity_assets() {
            add_chainlink(env, asset, btc_usd_feed(), VOLATILE_STALENESS);
        }

        let reference = env.price_oracle.price(wbtc());
        assert!(reference.is_valid, "the BTC/USD leg must price");
        // BTC was $79,314.03 at this block
        assert_in_band(reference.value, 10_000 * SCALE, 500_000 * SCALE, "BTC/USD");

        for asset in btc_parity_assets() {
            let price = env.price_oracle.price(asset);
            assert!(price.is_valid, "every parity-priced wrapper must be valid");
            assert!(price.value == reference.value, "parity pricing must be exact, not approximate");
        }
        // the decimals actually differ across that set, so the equality above is a real check
        assert!(IERC4626Dispatcher { contract_address: lbtc() }.decimals() == 8, "LBTC is 8 decimal");
        assert!(IERC4626Dispatcher { contract_address: ebtc() }.decimals() == 10, "eBTC is 10 decimal");
        assert!(IERC4626Dispatcher { contract_address: tbtc() }.decimals() == 18, "tBTC is 18 decimal");
    }

    /// §4.4 calls parity pricing "a regression against today's per-asset Pragma keys, which at least
    /// carry some market signal". Measured against the live oracle, that is true of **WBTC only**: it
    /// is the one BTC wrapper with its own Pragma key (`WBTC/USD`), and every other wrapper in the set
    /// is already on the shared `BTC/USD` key today. The basis below is the entire signal the switch
    /// gives up.
    #[test]
    #[fork("OracleMainnet")]
    fn test_fork_parity_pricing_only_loses_signal_for_wbtc() {
        let live = live_oracle();
        assert!(live.oracle_config(wbtc()).pragma_key == 'WBTC/USD', "WBTC is expected to have its own key");
        for asset in array![tbtc(), lbtc(), solvbtc(), strkbtc(), unibtc(), ybtc_b(), ebtc()] {
            assert!(
                live.oracle_config(asset).pragma_key == 'BTC/USD',
                "this wrapper is already parity-priced today, so sec 4.4 loses no signal for it",
            );
        }

        // and the basis that WBTC's own key currently carries: 10 bps at this block
        let env = setup();
        add_chainlink(env, wbtc(), btc_usd_feed(), VOLATILE_STALENESS);
        let basis = divergence_bps(env.price_oracle.price(wbtc()).value, live_price().price(wbtc()).value);
        assert!(basis < 300, "WBTC basis vs its own Pragma key is {} bps, wider than expected", basis);
    }

    // ------------------------------------------------------------------------------------------
    // §6.2 — staleness bounds, calibrated against observed feed ages
    // ------------------------------------------------------------------------------------------

    /// §6.2 claims a 1h bound suits the deviation-driven feeds while the flat-peg stablecoin feeds
    /// legitimately approach their 24h heartbeat, so a tight bound there "would produce constant false
    /// invalidations". Both halves are asserted against real `updated_at` gaps. Observed at this block:
    /// BTC 622s, ETH 141s, STRK 38s — and USDC 51,782s, USDT 51,983s.
    #[test]
    #[fork("OracleMainnet")]
    fn test_fork_staleness_bounds_match_observed_feed_ages() {
        let env = setup();
        add_chainlink(env, eth(), eth_usd_feed(), VOLATILE_STALENESS);
        add_chainlink(env, strk(), strk_usd_feed(), VOLATILE_STALENESS);
        add_chainlink(env, wbtc(), btc_usd_feed(), VOLATILE_STALENESS);
        for asset in array![eth(), strk(), wbtc()] {
            assert!(env.price_oracle.price(asset).is_valid, "a deviation-driven feed must be fresh within 1h");
        }

        // the stablecoin feeds are not, which is exactly why §6.2 sets them to 25h
        add_chainlink(env, usdc(), usdc_usd_feed(), VOLATILE_STALENESS);
        add_chainlink(env, usdt(), usdt_usd_feed(), VOLATILE_STALENESS);
        for asset in array![usdc(), usdt()] {
            let price = env.price_oracle.price(asset);
            assert!(!price.is_valid, "a 1h bound on a stablecoin feed must invalidate, vindicating the 25h bound");
            assert!(price.value != 0, "the stale value is still surfaced; only the flag decides");
        }

        let env = setup();
        add_chainlink(env, usdc(), usdc_usd_feed(), STABLE_STALENESS);
        add_chainlink(env, usdt(), usdt_usd_feed(), STABLE_STALENESS);
        for asset in array![usdc(), usdt()] {
            assert!(env.price_oracle.price(asset).is_valid, "a stablecoin feed must be valid under the 25h bound");
        }

        // record the margin the 25h bound actually leaves, and that 1h would not have sufficed
        for feed in array![usdc_usd_feed(), usdt_usd_feed()] {
            let age = get_block_timestamp()
                - IChainlinkAggregatorDispatcher { contract_address: feed }.latest_round_data().updated_at;
            assert!(age > VOLATILE_STALENESS, "fixture assumption: this feed is older than 1h, got {}", age);
            assert!(age < STABLE_STALENESS, "feed age {} has exceeded the recommended 25h bound", age);
        }
    }

    // ------------------------------------------------------------------------------------------
    // §3.3 / §8 — the composed Chainlink route, against the only ETH-quoted feed on Starknet
    // ------------------------------------------------------------------------------------------

    fn add_wsteth(env: Env, max_staleness: u64) {
        cheat_caller_address(env.oracle.contract_address, manager(), CheatSpan::TargetCalls(1));
        env
            .oracle
            .add_chainlink_asset(
                wsteth(),
                ChainlinkConfig { feed: wsteth_eth_feed(), feed_decimals: 0, max_staleness, quote_asset: eth() },
            );
    }

    /// §8 lists wstETH as having no acceptable route, pending "a new Chainlink feed (`wstETH/ETH` or
    /// `stETH/ETH`), routed as `Chainlink` with `quote_asset = ETH`". That feed exists, so this is that
    /// route — and the only live exercise of §3.3's composed Chainlink leg, since every other Starknet
    /// feed is USD-quoted and therefore terminal.
    ///
    /// It is also the only live feed that is not 8 decimal. A `feed_decimals` assumed rather than
    /// derived would misprice wstETH by ten orders of magnitude here, and pass everywhere else.
    #[test]
    #[fork("OracleMainnet")]
    fn test_fork_wsteth_composes_through_the_live_eth_leg() {
        let env = setup();
        add_chainlink(env, eth(), eth_usd_feed(), VOLATILE_STALENESS);
        add_wsteth(env, STABLE_STALENESS);

        assert!(env.oracle.chainlink_config(wsteth()).feed_decimals == 18, "feed decimals not derived from the feed");
        assert!(env.oracle.chainlink_config(wsteth()).quote_asset == eth(), "quote asset not stored");

        // the feed answers wstETH per ETH, which at 18 decimals is already SCALE denominated
        let round = IChainlinkAggregatorDispatcher { contract_address: wsteth_eth_feed() }.latest_round_data();
        let ratio: u256 = round.answer.into();
        // 1.24312988 ETH per wstETH at this block
        assert_in_band(ratio, SCALE, 2 * SCALE, "wstETH/ETH ratio");

        let eth_price = env.price_oracle.price(eth()).value;
        let price = env.price_oracle.price(wsteth());
        assert!(price.is_valid, "the composed wstETH price must be valid");
        assert!(price.value == ratio * eth_price / SCALE, "composition does not match ratio x ETH/USD");
        // ~$3,090 at this block
        assert_in_band(price.value, 500 * SCALE, 50_000 * SCALE, "wstETH/USD");
        assert!(price.value > eth_price, "wstETH must be worth more than ETH");

        // §3.3: one level of composition, so a composed route is never itself terminal
        assert!(!env.oracle.price_terminal(wsteth()).is_valid, "a composed Chainlink route is not terminal");

        // and the whole point of the route: it tracks the exchange rate, so it is not ETH parity
        assert!(divergence_bps(price.value, eth_price) > 1000, "wstETH must not price at ETH parity");
    }

    /// §3.3's rule that an invalid quote leg invalidates the composition, against live sources: a
    /// stale ETH/USD leg must take wstETH down with it rather than leaving it priced off a bare ratio.
    #[test]
    #[fork("OracleMainnet")]
    fn test_fork_wsteth_is_invalid_when_its_eth_leg_is() {
        let env = setup();
        // a 1 second bound makes the ETH leg stale at this block without touching the wstETH feed
        add_chainlink(env, eth(), eth_usd_feed(), 1);
        add_wsteth(env, STABLE_STALENESS);

        assert!(!env.price_oracle.price(eth()).is_valid, "fixture assumption: the ETH leg is stale");
        let price = env.price_oracle.price(wsteth());
        assert!(!price.is_valid, "an invalid quote leg must invalidate the composition");
        // §3.3: "the router never returns the bare ratio"
        let ratio: u256 = IChainlinkAggregatorDispatcher { contract_address: wsteth_eth_feed() }
            .latest_round_data()
            .answer
            .into();
        assert!(price.value != ratio, "the bare wstETH/ETH ratio must never be reported as a USD price");
    }

    /// §6.2 splits feeds into deviation-driven (1h) and flat-peg heartbeat (25h). The wstETH/ETH feed
    /// is a third case: an exchange rate that only moves with staking accrual, so it updates rarely
    /// despite not being a peg. Observed age at this block: 35,927s (10.0h) — an order of magnitude
    /// past the 1h bound, so it belongs on the slow bound.
    #[test]
    #[fork("OracleMainnet")]
    fn test_fork_wsteth_feed_needs_the_slow_staleness_bound() {
        let age = get_block_timestamp()
            - IChainlinkAggregatorDispatcher { contract_address: wsteth_eth_feed() }.latest_round_data().updated_at;
        assert!(age > VOLATILE_STALENESS, "fixture assumption: the wstETH feed is older than 1h, got {}", age);
        assert!(age < STABLE_STALENESS, "the wstETH feed age {} has exceeded the slow bound", age);

        let env = setup();
        add_chainlink(env, eth(), eth_usd_feed(), VOLATILE_STALENESS);
        add_wsteth(env, VOLATILE_STALENESS);
        assert!(!env.price_oracle.price(wsteth()).is_valid, "a 1h bound on an exchange-rate feed must invalidate");

        let env = setup();
        add_chainlink(env, eth(), eth_usd_feed(), VOLATILE_STALENESS);
        add_wsteth(env, STABLE_STALENESS);
        assert!(env.price_oracle.price(wsteth()).is_valid, "the slow bound must accommodate the wstETH feed");
    }

    /// §4.4 says parity pricing costs a depeg signal, and §4.2 routes WBTC to `BTC/USD`. WBTC now has
    /// its own Chainlink feed, so that cost is avoidable for the one asset where it was real. This
    /// measures both options against Pragma's independent `WBTC/USD` key rather than arguing about
    /// them: whichever route is chosen, the numbers are here.
    #[test]
    #[fork("OracleMainnet")]
    fn test_fork_wbtc_own_feed_beats_btc_parity_against_pragma() {
        let parity = setup();
        add_chainlink(parity, wbtc(), btc_usd_feed(), VOLATILE_STALENESS);
        let own = setup();
        add_chainlink(own, wbtc(), wbtc_usd_feed(), VOLATILE_STALENESS);

        let reference = live_price().price(wbtc()).value;
        let parity_bps = divergence_bps(parity.price_oracle.price(wbtc()).value, reference);
        let own_bps = divergence_bps(own.price_oracle.price(wbtc()).value, reference);

        assert!(own.price_oracle.price(wbtc()).is_valid, "the WBTC feed must price");
        // observed: BTC parity 10.1 bps, WBTC's own feed 5.7 bps, both against Pragma's WBTC/USD
        assert!(
            own_bps < parity_bps,
            "the dedicated feed ({} bps) should track WBTC closer than parity ({} bps)",
            own_bps,
            parity_bps,
        );
        // and the two Chainlink routes genuinely differ, i.e. the feed is not a BTC/USD alias
        assert!(
            parity.price_oracle.price(wbtc()).value != own.price_oracle.price(wbtc()).value,
            "WBTC/USD must not be an alias of BTC/USD",
        );
    }

    // ------------------------------------------------------------------------------------------
    // §4.3 / §11.3 — the Endur wrappers against their live conversion rates
    // ------------------------------------------------------------------------------------------

    fn assert_wrapper(env: Env, wrapper: ContractAddress, underlying: ContractAddress, name: ByteArray) {
        let erc4626 = IERC4626Dispatcher { contract_address: wrapper };
        assert!(erc4626.asset() == underlying, "{}: sec 4.3 underlying mismatch", name.clone());

        let config = env.oracle.scaled_config(wrapper);
        assert!(config.share_decimals == erc4626.decimals(), "{}: share decimals not derived", name.clone());
        assert!(
            config.underlying_decimals == IERC4626Dispatcher { contract_address: underlying }.decimals(),
            "{}: underlying decimals not derived",
            name.clone(),
        );

        // §6.3: every Endur wrapper is at or above parity, and inside the configured cone
        let (rate, rate_is_valid) = env.oracle.conversion_rate(wrapper);
        assert!(rate_is_valid, "{}: live rate outside the configured cone", name.clone());
        assert_in_band(rate, SCALE, 13 * SCALE / 10, "{} conversion rate");
        assert!(config.ref_rate.into() == rate, "{}: anchor is not the observed rate", name.clone());

        // §3.3: the composed price is the rate times the underlying's own price
        let base = env.price_oracle.price(underlying);
        let price = env.price_oracle.price(wrapper);
        assert!(price.is_valid, "{}: composed price must be valid", name.clone());
        assert!(price.value == rate * base.value / SCALE, "{}: composition does not match rate x base", name.clone());
        assert!(price.value > base.value, "{}: a yield bearing wrapper must be worth more than its underlying", name);
    }

    #[test]
    #[fork("OracleMainnet")]
    fn test_fork_endur_wrappers_price_off_their_live_rates() {
        let env = setup();
        setup_all_routes(env);

        assert_wrapper(env, xstrk(), strk(), "xSTRK");
        assert_wrapper(env, xwbtc(), wbtc(), "xWBTC");
        assert_wrapper(env, xlbtc(), lbtc(), "xLBTC");
        assert_wrapper(env, xsbtc(), solvbtc(), "xsBTC");
        assert_wrapper(env, xtbtc(), tbtc(), "xtBTC");
        assert_wrapper(env, xstrkbtc(), strkbtc(), "xstrkBTC");
    }

    /// §11.5 asks for `max_growth_per_second` to be "calibrated from observed rate history with
    /// headroom", and §10 step 2 makes that a migration deliverable. This is that calibration, taken
    /// from two real blocks 90.0 days apart rather than from a guess.
    ///
    /// Anchors read at block 10_630_064 (timestamp 1_780_998_914); the live end is read on-fork.
    /// Observed slopes [SCALE/s]: xSTRK 2_520_235_290 (6.86%/yr), xsBTC 710_793_164, xtBTC 690_759_636,
    /// xWBTC 689_835_777, xstrkBTC 679_797_920, xLBTC 89_115_227 (0.27%/yr). The recommended
    /// `MAX_GROWTH_PER_SECOND` of 1e10 leaves 4x headroom over the fastest of those, which is xSTRK's
    /// staking yield — the BTC wrappers run roughly 3.6x slower.

    /// Reads a wrapper's live rate and checks the slope implied against a historical anchor.
    fn assert_slope(wrapper: ContractAddress, then: u256, elapsed: u256, name: ByteArray) {
        let erc4626 = IERC4626Dispatcher { contract_address: wrapper };
        let shares = pow_10(erc4626.decimals().into());
        let underlying_decimals = IERC4626Dispatcher { contract_address: erc4626.asset() }.decimals();
        let now = erc4626.convert_to_assets(shares) * SCALE / pow_10(underlying_decimals.into());
        assert!(now > then, "{}: rate did not accrue over 90 days", name.clone());
        let slope = (now - then) / elapsed;
        assert!(
            slope <= MAX_GROWTH_PER_SECOND.into(),
            "{}: observed slope {} exceeds the recommended {}",
            name,
            slope,
            MAX_GROWTH_PER_SECOND,
        );
    }

    #[test]
    #[fork("OracleMainnet")]
    fn test_fork_cone_slope_covers_observed_wrapper_growth() {
        let elapsed: u256 = (BLOCK_TIMESTAMP - 1_780_998_914).into();

        assert_slope(xstrk(), 1158745252836112341, elapsed, "xSTRK");
        assert_slope(xwbtc(), 1021817710000000000, elapsed, "xWBTC");
        assert_slope(xlbtc(), 1022641730000000000, elapsed, "xLBTC");
        assert_slope(xsbtc(), 1022259091657090455, elapsed, "xsBTC");
        assert_slope(xtbtc(), 1021956779589940924, elapsed, "xtBTC");
        assert_slope(xstrkbtc(), 1001747590000000000, elapsed, "xstrkBTC");

        // and the recommended ceiling is not already breached by any live rate
        let env = setup();
        setup_all_routes(env);
        for wrapper in array![xstrk(), xwbtc(), xlbtc(), xsbtc(), xtbtc(), xstrkbtc()] {
            let (rate, _) = env.oracle.conversion_rate(wrapper);
            assert!(rate < MAX_RATE.into(), "a live rate has reached the recommended max_rate");
        }
    }

    /// §6.3's anchor refresh against a live wrapper: re-anchoring to the rate the wrapper currently
    /// reports is a no-op on the value and a reset of the timestamp, because the anchor was already
    /// taken from the same source at listing.
    #[test]
    #[fork("OracleMainnet")]
    fn test_fork_reanchor_against_a_live_wrapper() {
        let env = setup();
        // staleness disabled: this test advances the clock past the 1h bound, and a stale quote leg
        // would invalidate the composed price for a reason that has nothing to do with the anchor
        add_chainlink(env, strk(), strk_usd_feed(), 0);
        add_scaled(env, xstrk(), strk());
        let before = env.oracle.scaled_config(xstrk());

        start_cheat_block_timestamp_global(BLOCK_TIMESTAMP + 3600);
        cheat_caller_address(env.oracle.contract_address, manager(), CheatSpan::TargetCalls(1));
        env.oracle.reanchor(xstrk());

        let after = env.oracle.scaled_config(xstrk());
        assert!(after.ref_rate == before.ref_rate, "the live rate did not move, so the anchor must not either");
        assert!(after.ref_timestamp == BLOCK_TIMESTAMP + 3600, "the anchor timestamp must be refreshed");
        assert!(env.price_oracle.price(xstrk()).is_valid, "the route must still price after re-anchoring");
    }

    // ------------------------------------------------------------------------------------------
    // §5 — the Ekubo leg
    // ------------------------------------------------------------------------------------------

    /// The regression test for the `Option<u64>` return of `get_earliest_observation_time`. Reading it
    /// as a bare `u64` picks up the `Some` variant tag instead of the timestamp, which the
    /// `earliest == 0` guard then turns into "no history" — making every EkuboTwap route invalid on
    /// mainnet forever while every mock-based test still passed.
    #[test]
    #[fork("OracleMainnet")]
    fn test_fork_ekubo_extension_reports_real_observation_history() {
        let extension = IEkuboOracleDispatcher { contract_address: ekubo_oracle_extension() };
        let earliest = extension.get_earliest_observation_time(ekubo(), eth()).expect('pair must be tracked');
        assert!(earliest > 1_700_000_000, "earliest {} is a variant tag, not a timestamp", earliest);
        assert!(earliest + MIN_TWAP_WINDOW < BLOCK_TIMESTAMP, "EKUBO/ETH must have more than one window of history");
    }

    #[test]
    #[fork("OracleMainnet")]
    fn test_fork_ekubo_twap_composes_with_the_live_eth_feed() {
        let env = setup();
        add_chainlink(env, eth(), eth_usd_feed(), VOLATILE_STALENESS);
        add_ekubo(env, 3600);

        let (ratio, ratio_is_valid) = env.oracle.twap(ekubo(), 3600);
        assert!(ratio_is_valid, "the live EKUBO/ETH TWAP must resolve");
        // EKUBO/ETH was 0.000201414064807535 at this block
        assert_in_band(ratio, SCALE / 100_000, SCALE / 100, "EKUBO/ETH ratio");

        let price = env.price_oracle.price(ekubo());
        assert!(price.is_valid, "the composed EKUBO/USD price must be valid");
        assert!(price.value == ratio * env.price_oracle.price(eth()).value / SCALE, "composition mismatch");
        // implied EKUBO/USD was $0.5007
        assert_in_band(price.value, SCALE / 100, 50 * SCALE, "EKUBO/USD");

        // the minimum window resolves too, and the two windows agree closely on a real pool
        let short = setup();
        add_chainlink(short, eth(), eth_usd_feed(), VOLATILE_STALENESS);
        add_ekubo(short, MIN_TWAP_WINDOW);
        let (short_ratio, short_is_valid) = short.oracle.twap(ekubo(), MIN_TWAP_WINDOW);
        assert!(short_is_valid, "the minimum window must resolve on a live pair");
        assert_within_bps(short_ratio, ratio, 1000, "the 30m and 1h TWAPs disagree sharply");
    }

    /// §5: "MUST return `is_valid: false` if the extension has no observation older than the window
    /// (insufficient history), rather than silently shortening the window" — against a live pair whose
    /// history is real but finite.
    #[test]
    #[fork("OracleMainnet")]
    fn test_fork_ekubo_window_longer_than_live_history_is_invalid() {
        let env = setup();
        add_chainlink(env, eth(), eth_usd_feed(), VOLATILE_STALENESS);
        add_ekubo(env, 3600);

        let earliest = IEkuboOracleDispatcher { contract_address: ekubo_oracle_extension() }
            .get_earliest_observation_time(ekubo(), eth())
            .expect('pair must be tracked');
        let available = BLOCK_TIMESTAMP - earliest;

        let (ratio, is_valid) = env.oracle.twap(ekubo(), available + 1);
        assert!(!is_valid && ratio == 0, "a window one second longer than the history must be invalid");
        // one second inside it still resolves, so the boundary is where it is claimed to be
        let (_, is_valid) = env.oracle.twap(ekubo(), available);
        assert!(is_valid, "a window exactly covering the available history must resolve");
    }

    /// §5's advisory deviation bound, evaluated against the real pool rather than a fixture.
    #[test]
    #[fork("OracleMainnet")]
    fn test_fork_ekubo_spot_deviation_is_computable_and_advisory() {
        let env = setup();
        add_chainlink(env, eth(), eth_usd_feed(), VOLATILE_STALENESS);
        add_ekubo(env, 3600);

        let (deviation, is_valid) = env.oracle.spot_deviation(ekubo());
        assert!(is_valid, "spot deviation must be computable on a live pair");
        assert!(deviation < 50 * PERCENT, "a {} deviation on the live pool is implausible", deviation);
        // whatever it reads, it never invalidates — §5, and §6.0's reason for it
        assert!(env.price_oracle.price(ekubo()).is_valid, "spot deviation must stay advisory");
    }

    // ------------------------------------------------------------------------------------------
    // §3.3 / §3.4 — composition and failure isolation against live contracts
    // ------------------------------------------------------------------------------------------

    /// §3.3: the quote leg must resolve terminally. On live routes that means neither a Scaled asset
    /// nor an EkuboTwap asset can serve as one, which is checked at configuration time and — more
    /// importantly — is structural at read time.
    #[test]
    #[fork("OracleMainnet")]
    fn test_fork_live_composite_routes_are_not_usable_as_quote_legs() {
        let env = setup();
        setup_all_routes(env);

        // each composite route resolves, but not terminally
        for asset in array![xstrk(), xwbtc(), ekubo()] {
            assert!(env.price_oracle.price(asset).is_valid, "the composite route itself must price");
            assert!(!env.oracle.price_terminal(asset).is_valid, "a composite route must not resolve terminally");
        }
        // while the terminal routes behind them do
        for asset in array![strk(), wbtc(), eth()] {
            assert!(env.oracle.price_terminal(asset).is_valid, "a direct feed must resolve terminally");
        }
    }

    #[test]
    #[fork("OracleMainnet")]
    #[should_panic(expected: "quote-asset-not-terminal")]
    fn test_fork_a_live_scaled_asset_cannot_be_a_quote_leg() {
        let env = setup();
        setup_all_routes(env);
        // xSTRK is a live Scaled route; quoting anything in it must be refused at write time
        cheat_caller_address(env.oracle.contract_address, manager(), CheatSpan::TargetCalls(1));
        env
            .oracle
            .add_chainlink_asset(
                contract_address_const::<'new-asset'>(),
                ChainlinkConfig {
                    feed: eth_usd_feed(), feed_decimals: 0, max_staleness: VOLATILE_STALENESS, quote_asset: xstrk(),
                },
            );
    }

    /// §3.4 against a real contract rather than a mock: the EKUBO token is deployed and answers
    /// `decimals()`, so it passes configuration, but it has no `latest_round_data` entrypoint. That is
    /// the recoverable failure class, and it must degrade to `is_valid: false` rather than revert —
    /// which is what keeps a repointed feed from freezing repayment and liquidation.
    #[test]
    #[fork("OracleMainnet")]
    fn test_fork_a_live_contract_without_the_entrypoint_is_invalid_not_reverting() {
        let env = setup();
        add_chainlink(env, eth(), ekubo(), VOLATILE_STALENESS);
        assert!(env.oracle.route_kind(eth()) == PriceRouteKind::Chainlink, "the config-time read succeeded");

        let price = env.price_oracle.price(eth());
        assert!(!price.is_valid, "a source without the entrypoint must be reported invalid");
        assert!(price.value == 0, "a source without the entrypoint must not report a value");
    }

    // ------------------------------------------------------------------------------------------
    // §7 — a route change on live sources
    // ------------------------------------------------------------------------------------------

    /// Repointing a live asset's feed through the timelock. Staleness is disabled for this one so that
    /// advancing the clock past the timelock does not invalidate the feeds for an unrelated reason.
    #[test]
    #[fork("OracleMainnet")]
    fn test_fork_repointing_a_live_feed_through_the_timelock() {
        let env = setup();
        add_chainlink(env, eth(), eth_usd_feed(), 0);
        let before = env.price_oracle.price(eth());
        assert_in_band(before.value, 500 * SCALE, 20_000 * SCALE, "ETH/USD");

        cheat_caller_address(env.oracle.contract_address, manager(), CheatSpan::TargetCalls(1));
        env
            .oracle
            .propose_chainlink_route(
                eth(),
                ChainlinkConfig { feed: btc_usd_feed(), feed_decimals: 0, max_staleness: 0, quote_asset: Zero::zero() },
            );
        assert!(env.price_oracle.price(eth()).value == before.value, "the live route must survive the timelock");

        start_cheat_block_timestamp_global(BLOCK_TIMESTAMP + TIMELOCK);
        cheat_caller_address(env.oracle.contract_address, manager(), CheatSpan::TargetCalls(1));
        env.oracle.apply_route_change(eth());

        let after = env.price_oracle.price(eth());
        assert!(after.is_valid, "the repointed route must price");
        assert_in_band(after.value, 10_000 * SCALE, 500_000 * SCALE, "the BTC/USD feed is now live for this asset");
        assert!(env.oracle.chainlink_config(eth()).feed == btc_usd_feed(), "feed not repointed");
    }

    // ------------------------------------------------------------------------------------------
    // §8 / §10 — the legacy Pragma kind and migration safety
    // ------------------------------------------------------------------------------------------

    /// §8 removes the summary-stats TWAP, so §10 step 1 stops being behaviour-preserving for any asset
    /// whose live config sets `start_time_offset` / `time_window`. This checks all 24 live configs,
    /// replays each one into the router verbatim, and asserts the router reproduces the deployed
    /// oracle's price exactly — which is what step 1 claims.
    #[test]
    #[fork("OracleMainnet")]
    fn test_fork_every_live_pragma_config_migrates_unchanged() {
        let env = setup();
        let live = live_oracle();

        for asset in all_listed_assets() {
            let config = live.oracle_config(asset);
            assert!(config.pragma_key != 0, "fixture assumption: the asset is listed on the live oracle");
            assert!(
                config.start_time_offset == 0 && config.time_window == 0,
                "a live asset uses the Pragma TWAP removed in sec 8; migrating it is not behaviour preserving",
            );

            cheat_caller_address(env.oracle.contract_address, manager(), CheatSpan::TargetCalls(1));
            env.oracle.add_pragma_asset(asset, config);
            assert!(env.oracle.route_kind(asset) == PriceRouteKind::Pragma, "live config not accepted verbatim");

            // step 1 of the migration is only safe if this is an equality, not an approximation
            let migrated = env.price_oracle.price(asset);
            let deployed = live_price().price(asset);
            assert!(migrated.is_valid == deployed.is_valid, "validity diverges from the deployed oracle");
            assert!(migrated.value == deployed.value, "price diverges from the deployed oracle");
        }
    }

    /// The §8 assets have no acceptable route and stay on the legacy kind. Asserted explicitly so that
    /// a later change which quietly gives one of them a Chainlink or Scaled route has to come past
    /// this test and the §8 discussion behind it.
    #[test]
    #[fork("OracleMainnet")]
    fn test_fork_section_8_assets_stay_on_the_legacy_kind() {
        let env = setup();
        setup_all_routes(env);

        for asset in array![susn(), mre7btc(), mre7yield()] {
            assert!(env.oracle.route_kind(asset) == PriceRouteKind::Pragma, "a sec 8 asset must stay on Pragma");
            assert!(env.price_oracle.price(asset).is_valid, "a sec 8 asset must still price through Pragma");
            // and as a Pragma route it is terminal, so it may legitimately quote other assets
            assert!(env.oracle.price_terminal(asset).is_valid, "a Pragma route is terminal");
        }
    }

    // ------------------------------------------------------------------------------------------
    // Pair invariance against the deployed Prime pool
    //
    // The real thing throughout: the deployed `Prime` pool, real positions opened by real users, real
    // collateral shares and accrued debt, `Prime`'s own `max_ltv` for each pair, and the pool's own
    // `check_collateralization`. The only intervention is `set_oracle` as the curator, to point Prime at
    // this router instead of the deployed one — which is exactly what §10 step 8 does in production.
    //
    // No synthetic positions and no reimplementation of the solvency formula: every verdict below comes
    // out of the deployed pool.
    // ------------------------------------------------------------------------------------------

    fn deploy_mock_feed(decimals: u8, answer: u128) -> IMockChainlinkFeedDispatcher {
        IMockChainlinkFeedDispatcher {
            contract_address: deploy_with_args("MockChainlinkFeed", array![decimals.into(), answer.into()]),
        }
    }

    fn repoint_prime(env: Env) {
        cheat_caller_address(prime().contract_address, prime_curator(), CheatSpan::TargetCalls(1));
        prime().set_oracle(env.oracle.contract_address);
        assert!(prime().oracle() == env.oracle.contract_address, "Prime was not repointed at the router");
    }

    fn prime_ltv(collateral: ContractAddress, debt: ContractAddress, user: ContractAddress) -> (bool, u256) {
        let (solvent, collateral_value, debt_value) = prime().check_collateralization(collateral, debt, user);
        assert!(collateral_value != 0, "the position must have collateral value");
        (solvent, debt_value * SCALE / collateral_value)
    }

    /// `Prime`'s configured limit for the pair — the number the pool actually judges against, rather
    /// than one chosen by this test
    fn prime_max_ltv(collateral: ContractAddress, debt: ContractAddress) -> u256 {
        prime().pair_config(collateral, debt).max_ltv.into()
    }

    /// A real wstETH/ETH position in Prime, at 80.5% LTV. Sweeping ETH/USD across five orders of
    /// magnitude must not move its solvency or its LTV, because both of its legs are denominated in
    /// ETH. Only the wstETH/ETH exchange rate can move it — and the last block of this test shows a
    /// depeg doing exactly that.
    #[test]
    #[fork("OracleMainnet")]
    fn test_fork_prime_wsteth_eth_position_is_eth_price_invariant() {
        // the position as the deployed oracle sees it, before anything is touched
        let (live_solvent, live_ltv) = prime_ltv(wsteth(), eth(), wsteth_eth_user());
        assert!(live_solvent, "fixture assumption: the position is solvent on the deployed oracle");
        assert_in_band(live_ltv, 50 * PERCENT, 95 * PERCENT, "the position's live LTV");

        let env = setup();
        let eth_feed = deploy_mock_feed(8, 248_572_000_000); // the live ETH/USD answer
        add_chainlink(env, eth(), eth_feed.contract_address, VOLATILE_STALENESS);
        add_wsteth(env, STABLE_STALENESS);
        repoint_prime(env);

        // swapping Pragma for this router barely moves the position — the same shadow parity as §11.2,
        // now measured where it matters, on a real position's LTV
        let (solvent, router_ltv) = prime_ltv(wsteth(), eth(), wsteth_eth_user());
        assert!(solvent, "the position must stay solvent under the router");
        assert_within_bps(router_ltv, live_ltv, 100, "repointing the oracle moved the position's LTV");

        // now sweep the shared leg
        for eth_usd in array![
            1_000_000_000_u128, 100_000_000_000, 248_572_000_000, 1_000_000_000_000, 100_000_000_000_000,
        ] {
            eth_feed.set_answer(eth_usd);
            let (solvent, ltv) = prime_ltv(wsteth(), eth(), wsteth_eth_user());
            assert!(solvent, "solvency must not depend on ETH/USD (answer {})", eth_usd);
            assert_within_bps(ltv, router_ltv, 1, "the LTV moved with ETH/USD (answer {})");
        }

        // and the converse: a 20% fall in the exchange rate, with ETH/USD back at its live value
        eth_feed.set_answer(248_572_000_000);
        let rate: u256 = IChainlinkAggregatorDispatcher { contract_address: wsteth_eth_feed() }
            .latest_round_data()
            .answer
            .into();
        let depegged = setup();
        add_chainlink(depegged, eth(), eth_feed.contract_address, VOLATILE_STALENESS);
        let depegged_feed = deploy_mock_feed(18, (rate * 80 / 100).try_into().unwrap());
        cheat_caller_address(depegged.oracle.contract_address, manager(), CheatSpan::TargetCalls(1));
        depegged
            .oracle
            .add_chainlink_asset(
                wsteth(),
                ChainlinkConfig {
                    feed: depegged_feed.contract_address,
                    feed_decimals: 0,
                    max_staleness: STABLE_STALENESS,
                    quote_asset: eth(),
                },
            );
        repoint_prime(depegged);

        let (solvent, depegged_ltv) = prime_ltv(wsteth(), eth(), wsteth_eth_user());
        assert_within_bps(depegged_ltv, router_ltv * 100 / 80, 10, "a 20% depeg must raise the LTV by 25%");
        assert!(!solvent, "a 20% depeg must push this position under water");
    }

    /// The edge, on the real position and against `Prime`'s own `max_ltv`. A position at LTV `L` with a
    /// limit `M` flips exactly when the exchange rate falls to `L / M` of its current value, because
    /// the LTV scales inversely with the rate and nothing else in the pair moves. One basis point either
    /// side of that point must land on opposite sides of the pool's verdict.
    ///
    /// This replaces the synthetic-amount version of the same check: the position, the limit and the
    /// rate are all the deployed ones, and only the critical factor is computed.
    #[test]
    #[fork("OracleMainnet")]
    fn test_fork_prime_wsteth_position_flips_exactly_at_its_rate_limit() {
        let max_ltv = prime_max_ltv(wsteth(), eth());
        assert_in_band(max_ltv, 50 * PERCENT, SCALE, "Prime's configured max_ltv for wstETH/ETH");

        let eth_feed = deploy_mock_feed(8, 248_572_000_000);
        let rate: u256 = IChainlinkAggregatorDispatcher { contract_address: wsteth_eth_feed() }
            .latest_round_data()
            .answer
            .into();

        // the LTV this router gives the position at the live rate
        let baseline = setup();
        add_chainlink(baseline, eth(), eth_feed.contract_address, VOLATILE_STALENESS);
        add_wsteth(baseline, STABLE_STALENESS);
        repoint_prime(baseline);
        let (solvent, router_ltv) = prime_ltv(wsteth(), eth(), wsteth_eth_user());
        assert!(solvent, "the position must start out solvent");
        assert!(router_ltv < max_ltv, "fixture assumption: the position is inside its limit");

        // the rate at which it flips, derived from the pool's own numbers
        let critical = router_ltv * SCALE / max_ltv;

        assert_prime_wsteth_solvency_at(eth_feed, rate * (critical + critical / 10000) / SCALE, true);
        assert_prime_wsteth_solvency_at(eth_feed, rate * (critical - critical / 10000) / SCALE, false);
    }

    /// Repoints Prime at a router whose wstETH/ETH rate is `rate`, and asserts the pool's verdict.
    fn assert_prime_wsteth_solvency_at(eth_feed: IMockChainlinkFeedDispatcher, rate: u256, expected_solvent: bool) {
        let env = setup();
        add_chainlink(env, eth(), eth_feed.contract_address, VOLATILE_STALENESS);
        let feed = deploy_mock_feed(18, rate.try_into().unwrap());
        cheat_caller_address(env.oracle.contract_address, manager(), CheatSpan::TargetCalls(1));
        env
            .oracle
            .add_chainlink_asset(
                wsteth(),
                ChainlinkConfig {
                    feed: feed.contract_address, feed_decimals: 0, max_staleness: STABLE_STALENESS, quote_asset: eth(),
                },
            );
        repoint_prime(env);
        let (solvent, _) = prime_ltv(wsteth(), eth(), wsteth_eth_user());
        assert!(
            solvent == expected_solvent,
            "at a wstETH/ETH rate of {} the pool's verdict should be {}",
            rate,
            expected_solvent,
        );
    }

    /// The same for real Endur wrapper positions in Prime, with the live ERC-4626 conversion rate and
    /// the real `Scaled` route. The wrapper and its underlying share a denominator, so the underlying's
    /// USD price cancels out of the LTV.
    /// One test per pair: each needs the pool still pointed at the deployed oracle when it reads its
    /// baseline, and `set_oracle` is global to the pool.
    #[test]
    #[fork("OracleMainnet")]
    fn test_fork_prime_xstrk_position_is_strk_price_invariant() {
        assert_prime_wrapper_invariance(xstrk(), strk(), xstrk_strk_user(), 3_104_700, "xSTRK/STRK");
    }

    #[test]
    #[fork("OracleMainnet")]
    fn test_fork_prime_xwbtc_position_is_btc_price_invariant() {
        assert_prime_wrapper_invariance(xwbtc(), wbtc(), xwbtc_wbtc_user(), 7_931_402_700_000, "xWBTC/WBTC");
    }

    fn assert_prime_wrapper_invariance(
        wrapper: ContractAddress,
        underlying: ContractAddress,
        user: ContractAddress,
        live_answer: u128,
        name: ByteArray,
    ) {
        let max_ltv = prime_max_ltv(wrapper, underlying);
        assert_in_band(max_ltv, 50 * PERCENT, SCALE, "Prime's configured max_ltv for the pair");

        let (live_solvent, live_ltv) = prime_ltv(wrapper, underlying, user);
        assert!(live_solvent, "{}: fixture assumption: the position is solvent", name.clone());
        assert!(live_ltv < max_ltv, "{}: fixture assumption: inside Prime's limit", name.clone());

        let env = setup();
        let feed = deploy_mock_feed(8, live_answer);
        add_chainlink(env, underlying, feed.contract_address, VOLATILE_STALENESS);
        add_scaled(env, wrapper, underlying);
        repoint_prime(env);

        let (solvent, router_ltv) = prime_ltv(wrapper, underlying, user);
        assert!(solvent, "{}: must stay solvent under the router", name.clone());
        assert_within_bps(router_ltv, live_ltv, 200, "repointing the oracle moved the position's LTV");

        // Eight orders of magnitude of the underlying's USD price, from a thousandth of its live value to
        // a hundred thousand times it. None of it reaches the position, because both legs rescale
        // together — which is the whole claim, stated as strongly as the pool allows.
        for usd in array![
            live_answer / 1000, live_answer / 10, live_answer, live_answer * 1000, live_answer * 100_000,
        ] {
            feed.set_answer(usd);
            let (solvent, ltv) = prime_ltv(wrapper, underlying, user);
            assert!(solvent, "{}: solvency must not depend on the underlying's USD price", name.clone());
            assert!(ltv < max_ltv, "{}: the LTV must stay inside Prime's limit", name.clone());
            assert_within_bps(ltv, router_ltv, 1, "the LTV moved with the underlying's USD price");
        }
        // the conversion rate is the only input left, and it is the live one
        let (rate, rate_is_valid) = env.oracle.conversion_rate(wrapper);
        assert!(rate_is_valid && rate > SCALE, "{}: the live rate must be above parity", name);
    }

    // ------------------------------------------------------------------------------------------
    // §6.0 The liveness budget, against the deployed Prime pool
    //
    // §6.0 is the document's central risk claim: an invalid price freezes borrow, repay, withdraw **and
    // liquidation** on every pair listing the asset. These tests establish that against a real pool and
    // real positions, for each shape a failure can take — a terminal feed, a composite route's ratio
    // leg, a composite route's quote leg, and a `Scaled` route's quote leg.
    //
    // The pairs used put the composite's quote leg somewhere other than the debt asset, so that exactly
    // one leg can be taken down and the other observed to survive.
    //
    // **Which error a frozen update reports depends on how the source failed, and it is not always the
    // oracle one.** `update_position` runs `assert_position_invariants` before
    // `assert_security_invariants`, and the former reads the price *value*, which the router still
    // surfaces for a stale source (§6.1 — only the flag goes false). So:
    //
    // - a **stale** source keeps a non-zero value, the collateralization check passes on it, and the
    //   update is rejected by the named `invalid-oracle` assertion;
    // - a source that **died** — panicked, lost its entrypoint, answered zero — yields value `0`, which
    //   makes the position look infinitely levered, and the update is rejected as `not-collateralized`
    //   before the oracle assertion is ever reached.
    //
    // Both freeze the pair, which is what §6.0 claims. But the second reports a healthy position as
    // undercollateralized, which is the same message a genuinely unhealthy one produces — see the note
    // in §6.0. The tests below pin both messages so that a change in either is visible.
    //
    // **Suggested fix, and what it would do to these tests.** §6.0 recommends moving
    // `assert_security_invariants` ahead of `assert_position_invariants` in `pool.cairo`'s
    // `update_position`, so that the oracle is the named cause whenever it is the actual cause. If that
    // lands, the two `not-collateralized` expectations below become `invalid-oracle`, and **those two
    // failures are the fix working, not a regression** — update them rather than reverting the reorder.
    // The two tests that already expect `invalid-oracle` are unaffected.
    //
    // The reorder does not touch the liquidation path: `liquidate_position` calls
    // `compute_liquidation_amounts` before `update_position`, so the `mul_div division by zero` pinned in
    // `test_fork_prime_a_dead_source_does_not_make_a_healthy_position_liquidatable` survives it. A
    // complete fix needs a second part — an explicit price-validity check before that arithmetic.
    // ------------------------------------------------------------------------------------------

    /// wstETH (composed over ETH) as collateral, USDT as debt. Each leg is on a mock feed so any one of
    /// them can be invalidated independently.
    fn setup_wsteth_usdt(
        env: Env,
    ) -> (IMockChainlinkFeedDispatcher, IMockChainlinkFeedDispatcher, IMockChainlinkFeedDispatcher) {
        let eth_feed = deploy_mock_feed(8, 248_572_000_000);
        let usdt_feed = deploy_mock_feed(8, 99_997_438);
        let rate: u128 = IChainlinkAggregatorDispatcher { contract_address: wsteth_eth_feed() }
            .latest_round_data()
            .answer;
        let wsteth_feed = deploy_mock_feed(18, rate);
        add_chainlink(env, eth(), eth_feed.contract_address, VOLATILE_STALENESS);
        add_chainlink(env, usdt(), usdt_feed.contract_address, STABLE_STALENESS);
        cheat_caller_address(env.oracle.contract_address, manager(), CheatSpan::TargetCalls(1));
        env
            .oracle
            .add_chainlink_asset(
                wsteth(),
                ChainlinkConfig {
                    feed: wsteth_feed.contract_address,
                    feed_decimals: 0,
                    max_staleness: STABLE_STALENESS,
                    quote_asset: eth(),
                },
            );
        (eth_feed, usdt_feed, wsteth_feed)
    }

    /// xSTRK (Scaled over STRK) as collateral, USDT as debt.
    fn setup_xstrk_usdt(env: Env) -> (IMockChainlinkFeedDispatcher, IMockChainlinkFeedDispatcher) {
        let strk_feed = deploy_mock_feed(8, 3_104_700);
        let usdt_feed = deploy_mock_feed(8, 99_997_438);
        add_chainlink(env, strk(), strk_feed.contract_address, VOLATILE_STALENESS);
        add_chainlink(env, usdt(), usdt_feed.contract_address, STABLE_STALENESS);
        add_scaled(env, xstrk(), strk());
        (strk_feed, usdt_feed)
    }

    /// Withdraws one wei of collateral as the position's owner — the smallest possible position update,
    /// and enough to put the whole invariant stack in front of the oracle.
    fn touch_position(collateral: ContractAddress, debt: ContractAddress, user: ContractAddress) {
        cheat_caller_address(prime().contract_address, user, CheatSpan::TargetCalls(1));
        prime()
            .modify_position(
                ModifyPositionParams {
                    collateral_asset: collateral,
                    debt_asset: debt,
                    user,
                    collateral: Amount { denomination: AmountDenomination::Assets, value: I257Trait::new(1, true) },
                    debt: Default::default(),
                },
            );
    }

    /// §3.4's other half, on a real pool: however a source fails, the pool's *views* must keep answering.
    /// A reverting view would take the whole monitoring stack down with the feed, and would make the
    /// failure undiagnosable from outside.
    #[test]
    #[fork("OracleMainnet")]
    fn test_fork_prime_views_survive_every_invalid_route_shape() {
        // 1. a terminal feed — the debt leg — answers zero. Only that leg's value is lost; the pool
        // does not zero the whole position, it just stops being able to judge it.
        let env = setup();
        let (_, usdt_feed, _) = setup_wsteth_usdt(env);
        repoint_prime(env);
        usdt_feed.set_answer(0);
        assert!(!prime().price(usdt()).is_valid, "the terminal debt leg must be invalid");
        assert!(prime().price(wsteth()).is_valid, "the composite collateral leg must be unaffected");
        let (_, collateral_value, debt_value) = prime().check_collateralization(wsteth(), usdt(), wsteth_usdt_user());
        assert!(debt_value == 0, "a zero-answer debt leg must zero the debt value");
        assert!(collateral_value != 0, "the healthy collateral leg must still be valued");

        // 2. a composite route's own ratio leg panics
        let env = setup();
        let (_, _, wsteth_feed) = setup_wsteth_usdt(env);
        repoint_prime(env);
        wsteth_feed.set_should_panic(true);
        assert!(!prime().price(wsteth()).is_valid, "a panicking ratio leg must be invalid");
        assert!(prime().price(wsteth()).value == 0, "a dead source surfaces no value at all");
        assert!(prime().price(usdt()).is_valid, "the debt leg must be unaffected");
        let (_, collateral_value, debt_value) = prime().check_collateralization(wsteth(), usdt(), wsteth_usdt_user());
        assert!(collateral_value == 0 && debt_value != 0, "a dead collateral leg leaves the debt standing alone");

        // 3. a composite route's quote leg goes stale
        let env = setup();
        let (eth_feed, _, _) = setup_wsteth_usdt(env);
        repoint_prime(env);
        eth_feed.set_updated_at(BLOCK_TIMESTAMP - 100_000);
        assert!(!prime().price(eth()).is_valid, "the quote leg must be stale");
        assert!(!prime().price(wsteth()).is_valid, "a stale quote leg must invalidate the composition");
        // a stale leg still surfaces its last value, which is what sends this case down a different
        // assertion path than the dead-source case above
        assert!(prime().price(wsteth()).value != 0, "a stale composition still surfaces a value");
        assert!(prime().price(usdt()).is_valid, "the debt leg must be unaffected");
        prime().check_collateralization(wsteth(), usdt(), wsteth_usdt_user());

        // 4. a Scaled route's quote leg answers zero
        let env = setup();
        let (strk_feed, _) = setup_xstrk_usdt(env);
        repoint_prime(env);
        strk_feed.set_answer(0);
        assert!(!prime().price(xstrk()).is_valid, "a zero quote leg must invalidate the Scaled route");
        assert!(prime().price(usdt()).is_valid, "the debt leg must be unaffected");
        let (_, collateral_value, _) = prime().check_collateralization(xstrk(), usdt(), xstrk_usdt_user());
        assert!(collateral_value == 0, "an invalid Scaled route must zero the collateral value");
    }

    /// A sanity control for the four freeze tests below: with every leg healthy, the same one-wei
    /// withdrawal succeeds. Without this, a freeze test proves only that `modify_position` is hard to
    /// call, not that the oracle is what blocked it.
    #[test]
    #[fork("OracleMainnet")]
    fn test_fork_prime_position_is_modifiable_while_every_leg_is_valid() {
        let env = setup();
        setup_wsteth_usdt(env);
        repoint_prime(env);
        assert!(prime().price(wsteth()).is_valid && prime().price(usdt()).is_valid, "both legs must be valid");
        touch_position(wsteth(), usdt(), wsteth_usdt_user());
    }

    /// A terminal feed answers zero: the debt leg loses its value, the collateralization check passes
    /// vacuously on a zero debt, and the named oracle assertion is what rejects the update. Unaffected by
    /// §6.0's suggested reorder — this path already reports the oracle as the cause.
    #[test]
    #[fork("OracleMainnet")]
    #[should_panic(expected: "invalid-oracle")]
    fn test_fork_prime_frozen_by_an_invalid_terminal_feed() {
        let env = setup();
        let (_, usdt_feed, _) = setup_wsteth_usdt(env);
        repoint_prime(env);
        usdt_feed.set_answer(0);
        touch_position(wsteth(), usdt(), wsteth_usdt_user());
    }

    /// A composite route's own ratio leg *dies* — the feed panics, so no value survives. The position
    /// reads as infinitely levered and is rejected as `not-collateralized`, never reaching the oracle
    /// assertion. The pair is frozen either way; the diagnostic is the problem.
    ///
    /// If §6.0's suggested reorder of `update_position` lands, this expectation becomes `invalid-oracle`.
    /// A failure here after that change is the fix working — update the expectation, do not revert it.
    #[test]
    #[fork("OracleMainnet")]
    #[should_panic(expected: "not-collateralized")]
    fn test_fork_prime_frozen_by_an_invalid_composite_ratio_leg() {
        let env = setup();
        let (_, _, wsteth_feed) = setup_wsteth_usdt(env);
        repoint_prime(env);
        wsteth_feed.set_should_panic(true);
        touch_position(wsteth(), usdt(), wsteth_usdt_user());
    }

    /// A composite route's *quote* leg goes stale — ETH here, which the wstETH/USDT pair does not list.
    /// One asset's feed aging out freezes a pair that never mentions it. Stale, so a value survives and
    /// the named oracle assertion is reached. Unaffected by §6.0's suggested reorder.
    #[test]
    #[fork("OracleMainnet")]
    #[should_panic(expected: "invalid-oracle")]
    fn test_fork_prime_frozen_by_an_invalid_composite_quote_leg() {
        let env = setup();
        let (eth_feed, _, _) = setup_wsteth_usdt(env);
        repoint_prime(env);
        eth_feed.set_updated_at(BLOCK_TIMESTAMP - 100_000);
        touch_position(wsteth(), usdt(), wsteth_usdt_user());
    }

    /// A `Scaled` route's quote leg answers zero — dead rather than stale, so this lands on
    /// `not-collateralized` like the ratio-leg case above.
    ///
    /// If §6.0's suggested reorder of `update_position` lands, this expectation becomes `invalid-oracle`.
    /// A failure here after that change is the fix working — update the expectation, do not revert it.
    #[test]
    #[fork("OracleMainnet")]
    #[should_panic(expected: "not-collateralized")]
    fn test_fork_prime_frozen_by_an_invalid_scaled_quote_leg() {
        let env = setup();
        let (strk_feed, _) = setup_xstrk_usdt(env);
        repoint_prime(env);
        strk_feed.set_answer(0);
        touch_position(xstrk(), usdt(), xstrk_usdt_user());
    }

    fn attempt_liquidation() {
        prime()
            .liquidate_position(
                LiquidatePositionParams {
                    collateral_asset: wsteth(),
                    debt_asset: usdt(),
                    user: wsteth_usdt_user(),
                    min_collateral_to_receive: 0,
                    debt_to_repay: 1000,
                },
            );
    }

    /// §6.0's sharpest point: "an invalid price blocks the liquidations that a bad price is supposed to
    /// protect against". A liquidator cannot act on this position while the collateral leg is down, even
    /// for a trivial repayment.
    ///
    /// This is also what makes the misleading `not-collateralized` rejection **safe**. A dead source
    /// makes the collateral value read as zero, so a position update is refused as though the position
    /// were underwater — but the same zero makes `compute_liquidation_amounts` divide by the collateral
    /// price (`mul_div division by zero`), so the liquidation path reverts before it can act on that
    /// apparent insolvency. The misleading message is a bad diagnostic, not an exploitable one: nobody
    /// can take the collateral. Note the guard is incidental — it is a division by zero, not a check —
    /// which is worth keeping in mind if that arithmetic is ever reordered or made saturating.
    ///
    /// §6.0's suggested reorder of `update_position` does **not** change this expectation: the division
    /// happens in `compute_liquidation_amounts`, which `liquidate_position` calls before `update_position`
    /// is reached at all. Naming this failure properly needs a separate price-validity check ahead of
    /// that arithmetic; until then the protection here is accidental, and this test is what notices if it
    /// stops holding.
    #[test]
    #[fork("OracleMainnet")]
    // the specific panic matters: a bare `should_panic` here would also be satisfied by one of the
    // fixture assertions above, which would make this test vacuous
    #[should_panic(expected: ('mul_div division by zero',))]
    fn test_fork_prime_a_dead_source_does_not_make_a_healthy_position_liquidatable() {
        let env = setup();
        let (eth_feed, _, _) = setup_wsteth_usdt(env);
        repoint_prime(env);

        // the position is comfortably healthy while the oracle works: 45.5% LTV against Prime's 80% limit
        let max_ltv = prime_max_ltv(wsteth(), usdt());
        let (solvent, ltv) = prime_ltv(wsteth(), usdt(), wsteth_usdt_user());
        assert!(solvent, "fixture assumption: the position is solvent");
        assert!(ltv + 20 * PERCENT < max_ltv, "fixture assumption: at least 20 points of headroom, got {}", ltv);

        // kill the composite's quote leg outright, so no value survives
        eth_feed.set_answer(0);
        assert!(!prime().price(wsteth()).is_valid, "the collateral leg must be invalid");
        assert!(prime().price(wsteth()).value == 0, "a dead source must surface no value");
        let (_, collateral_value, debt_value) = prime().check_collateralization(wsteth(), usdt(), wsteth_usdt_user());
        assert!(collateral_value == 0 && debt_value != 0, "this is the state that reads as undercollateralized");

        // and yet it cannot be liquidated
        attempt_liquidation();
    }

    /// The control for the test above: with every leg healthy, the same liquidation attempt on the same
    /// position is refused by the pool's *honest* assertion. Two different failures, so the revert above
    /// is not merely "liquidation is hard to call".
    #[test]
    #[fork("OracleMainnet")]
    #[should_panic(expected: "not-undercollateralized")]
    fn test_fork_prime_a_healthy_position_is_refused_liquidation_with_the_honest_message() {
        let env = setup();
        setup_wsteth_usdt(env);
        repoint_prime(env);
        assert!(prime().price(wsteth()).is_valid && prime().price(usdt()).is_valid, "both legs must be valid");
        attempt_liquidation();
    }

    /// The third leg of the argument: the dead-source freeze leaves no residue. Once the source answers
    /// again the position is byte-for-byte as healthy as before, and updatable again — so the window
    /// during which it read as undercollateralized cost it nothing.
    #[test]
    #[fork("OracleMainnet")]
    fn test_fork_prime_a_dead_source_freeze_is_reversible_and_leaves_no_residue() {
        let env = setup();
        let (eth_feed, _, _) = setup_wsteth_usdt(env);
        repoint_prime(env);
        let (_, healthy_ltv) = prime_ltv(wsteth(), usdt(), wsteth_usdt_user());

        eth_feed.set_answer(0);
        assert!(!prime().price(wsteth()).is_valid, "the collateral leg must be dead");
        let (_, collateral_value, _) = prime().check_collateralization(wsteth(), usdt(), wsteth_usdt_user());
        assert!(collateral_value == 0, "the collateral value must be lost while the source is dead");

        eth_feed.set_answer(248_572_000_000);
        assert!(prime().price(wsteth()).is_valid, "the collateral leg must recover with its source");
        let (solvent, restored_ltv) = prime_ltv(wsteth(), usdt(), wsteth_usdt_user());
        assert!(solvent, "the position must be solvent again");
        assert!(restored_ltv == healthy_ltv, "the position's LTV must be exactly what it was before");

        // and it can be modified again, so the freeze was transient
        touch_position(wsteth(), usdt(), wsteth_usdt_user());
    }

    // ------------------------------------------------------------------------------------------
    // §11.2 / §6.6 — shadow parity across every planned route
    // ------------------------------------------------------------------------------------------

    /// The in-miniature §10.2 shadow run: every asset's intended §4.2 route against the price the
    /// deployed oracle returns through Pragma. These are genuinely independent sources, so the
    /// tolerances are the interesting output — they are what §6.6 would need before any deviation
    /// check could become an invalidating rule.
    ///
    /// Observed divergence at this block: ETH 16 bps, USDC 1 bps, USDT 17 bps, STRK 3 bps,
    /// BTC-parity wrappers 36 bps (Chainlink BTC/USD vs Pragma BTC/USD), WBTC 10 bps,
    /// Endur wrappers single-digit to tens of bps, EKUBO 47 bps.
    #[test]
    #[fork("OracleMainnet")]
    fn test_fork_shadow_parity_across_every_planned_route() {
        let env = setup();
        setup_all_routes(env);
        let live = live_price();

        // wstETH: an ETH-quoted feed composed over ETH/USD, against Pragma's own WSTETH/USD key —
        // two fully independent derivations. Observed: 22 bps.
        assert_within_bps(
            env.price_oracle.price(wsteth()).value, live.price(wsteth()).value, 100, "wstETH diverges from Pragma",
        );

        // direct feeds: tightest, both sides are aggregated spot over the same asset
        for asset in array![eth(), usdc(), usdc_second(), usdt(), strk()] {
            let new_price = env.price_oracle.price(asset);
            let old_price = live.price(asset);
            assert!(new_price.is_valid && old_price.is_valid, "both sources must be valid to compare");
            assert_within_bps(new_price.value, old_price.value, 100, "a direct feed diverges from Pragma");
        }

        // BTC parity: the divergence here is Chainlink BTC/USD against Pragma's BTC/USD or WBTC/USD
        for asset in btc_parity_assets() {
            assert_within_bps(
                env.price_oracle.price(asset).value, live.price(asset).value, 200, "a BTC wrapper diverges from Pragma",
            );
        }

        // Endur wrappers: an on-chain conversion rate over a Chainlink leg, against Pragma's
        // CONVERSION_* keys — two independent derivations of the same quantity
        for wrapper in array![xstrk(), xwbtc(), xlbtc(), xsbtc(), xtbtc(), xstrkbtc()] {
            assert_within_bps(
                env.price_oracle.price(wrapper).value,
                live.price(wrapper).value,
                200,
                "an Endur wrapper diverges from Pragma's conversion key",
            );
        }

        // EKUBO is the widest leg: a thin pool's geomean TWAP times ETH/USD, against Pragma's own
        // EKUBO/USD key. §5 predicts exactly this ordering.
        let ekubo_bps = divergence_bps(env.price_oracle.price(ekubo()).value, live.price(ekubo()).value);
        assert!(ekubo_bps < 300, "EKUBO diverges from Pragma by {} bps", ekubo_bps);
    }

    /// Every planned route resolving on one router at one block — the closest thing to a dress
    /// rehearsal for §10 step 8, where a pool is pointed at the router and reads all of these.
    #[test]
    #[fork("OracleMainnet")]
    fn test_fork_every_planned_route_resolves_on_one_router() {
        let env = setup();
        setup_all_routes(env);

        for asset in all_listed_assets() {
            let price = env.price_oracle.price(asset);
            assert!(price.is_valid, "a planned route does not resolve");
            assert!(price.value != 0, "a planned route prices zero");
        }
        // and the kinds are the ones §4.2 plans, not whatever happened to be configured
        for asset in array![eth(), usdc(), usdc_second(), usdt(), strk()] {
            assert!(env.oracle.route_kind(asset) == PriceRouteKind::Chainlink, "expected a direct Chainlink route");
        }
        // wstETH is a Chainlink route too, but a composed one
        assert!(env.oracle.route_kind(wsteth()) == PriceRouteKind::Chainlink, "expected a Chainlink route for wstETH");
        assert!(env.oracle.chainlink_config(wsteth()).quote_asset == eth(), "wstETH must compose over ETH");
        for asset in btc_parity_assets() {
            assert!(env.oracle.route_kind(asset) == PriceRouteKind::Chainlink, "expected a parity Chainlink route");
        }
        for asset in array![xstrk(), xwbtc(), xlbtc(), xsbtc(), xtbtc(), xstrkbtc()] {
            assert!(env.oracle.route_kind(asset) == PriceRouteKind::Scaled, "expected a Scaled route");
        }
        assert!(env.oracle.route_kind(ekubo()) == PriceRouteKind::EkuboTwap, "expected an EkuboTwap route");
    }
}
