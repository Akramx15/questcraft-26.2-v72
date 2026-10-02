package org.questcraft.veq.client.input;

/** Deterministic priority gate: wrist > climbing > interaction module > radial. */
public final class GripArbitration {
    private GripArbitration() {
    }

    public static Owner choose(boolean wristFocused, boolean interactionModuleActive, boolean radialEnabled) {
        return choose(wristFocused, interactionModuleActive, false, radialEnabled);
    }

    public static Owner choose(
            boolean wristFocused,
            boolean interactionModuleActive,
            boolean climbingOwnsGrip,
            boolean radialEnabled
    ) {
        if (wristFocused) {
            return Owner.WRIST;
        }
        if (climbingOwnsGrip) {
            return Owner.CLIMBING;
        }
        if (interactionModuleActive) {
            return Owner.INTERACTION_MODULE;
        }
        return radialEnabled ? Owner.RADIAL : Owner.NONE;
    }

    public enum Owner {
        WRIST,
        CLIMBING,
        INTERACTION_MODULE,
        RADIAL,
        NONE
    }
}
