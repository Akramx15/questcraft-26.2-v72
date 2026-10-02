package org.questcraft.veq.client.input;

import net.minecraft.world.InteractionHand;

/** Distinguishes VEQ's own held offhand use from a competing hand owner. */
final class OffhandUseContinuationPolicy {
    private OffhandUseContinuationPolicy() {
    }

    static boolean blocksWorldUse(
            boolean handsBusy,
            boolean usingItem,
            InteractionHand usedHand,
            boolean externalOffhandHeld
    ) {
        boolean ownedContinuation = externalOffhandHeld && usingItem &&
                usedHand == InteractionHand.OFF_HAND;
        return (handsBusy || usingItem) && !ownedContinuation;
    }

    static boolean shouldDispatchUse(
            boolean routed,
            boolean ownedContinuation,
            boolean cooldownReady
    ) {
        return routed && !ownedContinuation && cooldownReady;
    }
}
