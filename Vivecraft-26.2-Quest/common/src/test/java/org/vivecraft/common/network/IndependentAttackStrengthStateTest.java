package org.vivecraft.common.network;

import org.junit.jupiter.api.Assertions;
import org.junit.jupiter.api.Test;

class IndependentAttackStrengthStateTest {
    @Test
    void activationStartsReadyAndWeaponChangeResetsBothClocks() {
        IndependentAttackStrengthState state = new IndependentAttackStrengthState();
        Assertions.assertTrue(state.setEnabled(true));
        Assertions.assertEquals(1.0F, state.attackStrengthScale(0.0F, 20.0F));
        Assertions.assertEquals(1.0F, state.itemSwapScale(0.0F, 20.0F));

        state.tick(true);
        Assertions.assertEquals(0, state.attackStrengthTicker());
        Assertions.assertEquals(0, state.itemSwapTicker());
    }

    @Test
    void attackResetDoesNotResetOffhandItemSwapAnimation() {
        IndependentAttackStrengthState state = new IndependentAttackStrengthState();
        state.setEnabled(true);
        state.resetAttackAndSwap();
        state.tick(false);
        state.tick(false);
        state.resetAttackOnly();

        Assertions.assertEquals(0, state.attackStrengthTicker());
        Assertions.assertEquals(2, state.itemSwapTicker());
    }

    @Test
    void independentInstancesDoNotResetEachOther() {
        IndependentAttackStrengthState right = new IndependentAttackStrengthState();
        IndependentAttackStrengthState left = new IndependentAttackStrengthState();
        right.setEnabled(true);
        left.setEnabled(true);
        left.resetAttackAndSwap();

        Assertions.assertEquals(1.0F, right.attackStrengthScale(0.0F, 20.0F));
        Assertions.assertEquals(0.0F, left.attackStrengthScale(0.0F, 20.0F));
        Assertions.assertTrue(left.cannotAttack(0.9F, 0, 20.0F));
        Assertions.assertFalse(right.cannotAttack(0.9F, 0, 20.0F));
    }

    @Test
    void disablingMakesStateInertUntilFreshNegotiation() {
        IndependentAttackStrengthState state = new IndependentAttackStrengthState();
        state.setEnabled(true);
        state.resetAttackAndSwap();
        state.setEnabled(false);
        state.tick(false);
        Assertions.assertEquals(0, state.attackStrengthTicker());
        Assertions.assertTrue(state.setEnabled(true));
        Assertions.assertEquals(1.0F, state.attackStrengthScale(0.0F, 20.0F));
    }
}
