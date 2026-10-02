package org.questcraft.veq.client.config;

import net.minecraft.world.InteractionHand;

public enum WristHand {
    OFF_HAND(InteractionHand.OFF_HAND, 1),
    MAIN_HAND(InteractionHand.MAIN_HAND, 0);

    private final InteractionHand interactionHand;
    private final int controllerIndex;

    WristHand(InteractionHand interactionHand, int controllerIndex) {
        this.interactionHand = interactionHand;
        this.controllerIndex = controllerIndex;
    }

    public InteractionHand interactionHand() {
        return interactionHand;
    }

    /** Vivecraft indexes the logical main/off hand as controller 0/1. */
    public int controllerIndex() {
        return controllerIndex;
    }

    public WristHand next() {
        return this == OFF_HAND ? MAIN_HAND : OFF_HAND;
    }
}
