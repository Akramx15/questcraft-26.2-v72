package org.questcraft.veq.client.radial;

import org.vivecraft.client_vr.provider.ControllerType;

import java.util.Arrays;

/** Independent visual/choice state for MAIN and OFFHAND Grip menus. */
public final class HotbarHandState {
    static final long REJECTION_NANOS = 250_000_000L;
    private static final int[] LAST_CHOICE = new int[ControllerType.values().length];
    private static final int[] HOVERED_SLOT = new int[ControllerType.values().length];
    private static final int[] REJECTED_SLOT = new int[ControllerType.values().length];
    private static final long[] REJECTED_UNTIL = new long[ControllerType.values().length];
    private static final int[] PENDING_SLOT = new int[ControllerType.values().length];

    static {
        Arrays.fill(LAST_CHOICE, -1);
        Arrays.fill(HOVERED_SLOT, -1);
        Arrays.fill(REJECTED_SLOT, -1);
        Arrays.fill(PENDING_SLOT, -1);
    }

    private HotbarHandState() {
    }

    public static void accepted(ControllerType controller, int slot) {
        if (controller == null) {
            return;
        }
        LAST_CHOICE[controller.ordinal()] = slot;
        REJECTED_SLOT[controller.ordinal()] = -1;
        REJECTED_UNTIL[controller.ordinal()] = 0L;
    }

    public static void rejected(ControllerType controller, int slot, long nowNanos) {
        if (controller == null) {
            return;
        }
        REJECTED_SLOT[controller.ordinal()] = slot;
        REJECTED_UNTIL[controller.ordinal()] = nowNanos + REJECTION_NANOS;
    }

    public static int lastChoice(ControllerType controller) {
        return controller == null ? -1 : LAST_CHOICE[controller.ordinal()];
    }

    public static void hovered(ControllerType controller, int slot) {
        if (controller != null) {
            HOVERED_SLOT[controller.ordinal()] = slot;
        }
    }

    /** Starts a new one-surface session without carrying a prior hover into it. */
    public static void beginSession() {
        Arrays.fill(HOVERED_SLOT, -1);
    }

    /** Clears only the logical hand taking ownership of the shared surface. */
    public static void beginSession(ControllerType controller) {
        if (controller != null) {
            HOVERED_SLOT[controller.ordinal()] = -1;
        }
    }

    /** A lost/invalid ray cannot retain a releasable selection. */
    public static void updateHover(ControllerType controller, boolean pointed, int slot) {
        if (controller != null) {
            HOVERED_SLOT[controller.ordinal()] = pointed ? slot : -1;
        }
    }

    public static boolean hasCurrentHover(ControllerType controller) {
        int slot = hovered(controller);
        return slot >= 0 && slot < 9;
    }

    public static int hovered(ControllerType controller) {
        return controller == null ? -1 : HOVERED_SLOT[controller.ordinal()];
    }

    public static boolean isRejected(ControllerType controller, int slot, long nowNanos) {
        return controller != null && REJECTED_SLOT[controller.ordinal()] == slot &&
                nowNanos < REJECTED_UNTIL[controller.ordinal()];
    }

    public static int rejectedSlot(ControllerType controller, long nowNanos) {
        if (controller == null || nowNanos >= REJECTED_UNTIL[controller.ordinal()]) {
            return -1;
        }
        return REJECTED_SLOT[controller.ordinal()];
    }

    public static void pending(ControllerType controller, int slot) {
        if (controller != null) {
            PENDING_SLOT[controller.ordinal()] = slot;
        }
    }

    public static boolean isPending(ControllerType controller, int slot) {
        return controller != null && PENDING_SLOT[controller.ordinal()] == slot;
    }

    public static int pendingSlot(ControllerType controller) {
        return controller == null ? -1 : PENDING_SLOT[controller.ordinal()];
    }

    public static void clearPending(ControllerType controller) {
        if (controller != null) {
            PENDING_SLOT[controller.ordinal()] = -1;
        }
    }

    /** Clears feedback that must not survive cancellation or a world transition. */
    public static void clearTransient() {
        Arrays.fill(HOVERED_SLOT, -1);
        Arrays.fill(REJECTED_SLOT, -1);
        Arrays.fill(REJECTED_UNTIL, 0L);
        Arrays.fill(PENDING_SLOT, -1);
    }
}
