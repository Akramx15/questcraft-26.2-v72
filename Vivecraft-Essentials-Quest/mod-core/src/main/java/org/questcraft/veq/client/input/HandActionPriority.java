package org.questcraft.veq.client.input;

/** Per-logical-hand ownership: wrist > tracker > immersive/climb > Grip > world. */
public final class HandActionPriority {
    private HandActionPriority() {
    }

    public static Owner choose(
            boolean wristFocused,
            boolean trackerFocused,
            boolean immersiveFocused,
            boolean climbingFocused,
            boolean sameHandGripShowing
    ) {
        if (wristFocused) {
            return Owner.WRIST;
        }
        if (trackerFocused) {
            return Owner.TRACKER;
        }
        if (immersiveFocused) {
            return Owner.IMMERSIVE;
        }
        if (climbingFocused) {
            return Owner.CLIMBING;
        }
        if (sameHandGripShowing) {
            return Owner.GRIP;
        }
        return Owner.WORLD;
    }

    public enum Owner {
        WRIST,
        TRACKER,
        IMMERSIVE,
        CLIMBING,
        GRIP,
        WORLD
    }
}
