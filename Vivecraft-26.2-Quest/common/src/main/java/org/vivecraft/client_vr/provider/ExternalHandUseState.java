package org.vivecraft.client_vr.provider;

/**
 * Tiny integration hook for a separately routed handed use action. It only
 * keeps Minecraft from releasing an item already started through OFF_HAND;
 * it cannot initiate a use or change the global hit result.
 */
public final class ExternalHandUseState {
    private static boolean held;

    private ExternalHandUseState() {
    }

    public static boolean isHeld() {
        return held;
    }

    public static void setHeld(boolean value) {
        held = value;
    }
}
