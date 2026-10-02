package org.vivecraft.common.network;

/**
 * Allocation-free attack and item-swap clocks for the offhand. Vanilla's
 * existing fields remain the main-hand clocks and the fallback for peers that
 * did not negotiate {@link NetworkVersion#INDEPENDENT_HAND_COOLDOWN}.
 */
public final class IndependentAttackStrengthState {
    private static final int READY_TICKS = 1_000_000;

    private boolean enabled;
    private int attackStrengthTicker = READY_TICKS;
    private int itemSwapTicker = READY_TICKS;

    /** Returns true only on a disabled-to-enabled transition. */
    public boolean setEnabled(boolean enabled) {
        if (this.enabled == enabled) {
            return false;
        }
        this.enabled = enabled;
        if (enabled) {
            this.attackStrengthTicker = READY_TICKS;
            this.itemSwapTicker = READY_TICKS;
        }
        return enabled;
    }

    public boolean enabled() {
        return this.enabled;
    }

    public void tick(boolean itemTypeChanged) {
        if (!this.enabled) {
            return;
        }
        this.attackStrengthTicker = saturatingIncrement(this.attackStrengthTicker);
        this.itemSwapTicker = saturatingIncrement(this.itemSwapTicker);
        if (itemTypeChanged) {
            resetAttackAndSwap();
        }
    }

    public boolean cannotAttack(float minimumAttackCharge, int tolerance, float attackDelay) {
        float optimisticStrength = (this.attackStrengthTicker + tolerance) / safeDelay(attackDelay);
        return minimumAttackCharge > 0.0F && optimisticStrength < minimumAttackCharge;
    }

    public float attackStrengthScale(float partialTick, float attackDelay) {
        return clamp01((this.attackStrengthTicker + partialTick) / safeDelay(attackDelay));
    }

    public float itemSwapScale(float partialTick, float attackDelay) {
        return clamp01((this.itemSwapTicker + partialTick) / safeDelay(attackDelay));
    }

    public void resetAttackAndSwap() {
        this.attackStrengthTicker = 0;
        this.itemSwapTicker = 0;
    }

    public void resetAttackOnly() {
        this.attackStrengthTicker = 0;
    }

    int attackStrengthTicker() {
        return this.attackStrengthTicker;
    }

    int itemSwapTicker() {
        return this.itemSwapTicker;
    }

    private static int saturatingIncrement(int value) {
        return value == Integer.MAX_VALUE ? value : value + 1;
    }

    private static float safeDelay(float attackDelay) {
        return Math.max(attackDelay, Float.MIN_NORMAL);
    }

    private static float clamp01(float value) {
        return Math.max(0.0F, Math.min(1.0F, value));
    }
}
