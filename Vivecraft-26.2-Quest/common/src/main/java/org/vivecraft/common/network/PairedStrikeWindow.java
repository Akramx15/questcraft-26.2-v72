package org.vivecraft.common.network;

import org.vivecraft.api.data.VRBodyPart;

import javax.annotation.Nullable;
import java.util.UUID;

/**
 * Allocation-free record of the first successful hit in a possible
 * opposite-hand pair. Minecraft objects and item snapshots remain owned by
 * {@code ServerVivePlayer}; this class contains only the timing/gate policy.
 */
public final class PairedStrikeWindow {
    @Nullable
    private UUID target;
    @Nullable
    private VRBodyPart hand;
    private long tick = Long.MIN_VALUE;
    private float charge;

    public boolean armed() {
        return this.target != null && this.hand != null;
    }

    public VRBodyPart hand() {
        return this.hand;
    }

    public boolean record(
        UUID target, VRBodyPart hand, long tick, float attackCharge, float minimumCharge)
    {
        if (target == null || !isAttackHand(hand) || !Float.isFinite(attackCharge) ||
            !Float.isFinite(minimumCharge) || attackCharge < minimumCharge)
        {
            clear();
            return false;
        }
        this.target = target;
        this.hand = hand;
        this.tick = tick;
        this.charge = attackCharge;
        return true;
    }

    public boolean canPair(
        UUID target,
        VRBodyPart currentHand,
        long currentTick,
        int windowTicks,
        float currentCharge,
        float minimumCharge,
        boolean featureAllowed,
        boolean targetAllowed,
        boolean previousItemMatches)
    {
        if (!featureAllowed || !targetAllowed || !previousItemMatches || !armed() ||
            target == null || !isAttackHand(currentHand) || currentHand == this.hand ||
            !target.equals(this.target) || !Float.isFinite(currentCharge) ||
            !Float.isFinite(minimumCharge) || this.charge < minimumCharge ||
            currentCharge < minimumCharge)
        {
            return false;
        }

        long elapsed = currentTick - this.tick;
        return windowTicks >= 0 && elapsed >= 0L && elapsed <= windowTicks;
    }

    /** Clears stale or invalid first-hit state and reports whether it remains armed. */
    public boolean maintain(
        long currentTick,
        int windowTicks,
        boolean sameWorld,
        boolean previousItemMatches)
    {
        long elapsed = currentTick - this.tick;
        if (!armed() || !sameWorld || !previousItemMatches || windowTicks < 0 ||
            elapsed < 0L || elapsed > windowTicks)
        {
            clear();
        }
        return armed();
    }

    public void clear() {
        this.target = null;
        this.hand = null;
        this.tick = Long.MIN_VALUE;
        this.charge = 0.0F;
    }

    private static boolean isAttackHand(VRBodyPart hand) {
        return hand == VRBodyPart.MAIN_HAND || hand == VRBodyPart.OFF_HAND;
    }
}
