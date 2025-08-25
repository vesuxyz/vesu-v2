#[cfg(test)]
mod TestPoolFactory {
    use core::num::traits::Zero;
    use vesu::test::setup_v2::{Env, create_pool_via_factory, setup_env};

    #[test]
    fn test_pool_factory_create_pool() {
        let Env {
            pool_factory, oracle, config, users, ..,
        } = setup_env(Zero::zero(), Zero::zero(), Zero::zero(), Zero::zero());
        create_pool_via_factory(pool_factory, oracle, config, users.owner, users.curator, Option::None);
    }
}
