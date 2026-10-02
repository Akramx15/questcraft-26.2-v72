package org.questcraft.veq.client.input;

import net.minecraft.world.InteractionHand;
import org.vivecraft.client_vr.provider.ControllerType;

/**
 * One mapping contract for Quest input after the provider boundary.
 * ControllerType is always logical: RIGHT=main, LEFT=offhand. The OpenXR
 * provider alone converts physical paths for reverseHands; MCVR's haptic
 * scheduler performs the inverse conversion when output crosses back out.
 */
public final class QuestHandMapping {
    private QuestHandMapping() {
    }

    public static ControllerType logicalFromPhysical(
            ControllerType physicalController,
            boolean reverseHands
    ) {
        if (physicalController == null || !reverseHands) {
            return physicalController;
        }
        return physicalController == ControllerType.RIGHT
                ? ControllerType.LEFT
                : ControllerType.RIGHT;
    }

    public static ControllerType physicalFromLogical(
            ControllerType logicalController,
            boolean reverseHands
    ) {
        return logicalFromPhysical(logicalController, reverseHands);
    }

    public static InteractionHand interactionHand(ControllerType logicalController) {
        if (logicalController == null) {
            throw new IllegalArgumentException("Logical controller is required");
        }
        return logicalController == ControllerType.RIGHT
                ? InteractionHand.MAIN_HAND
                : InteractionHand.OFF_HAND;
    }

    public static int poseIndex(ControllerType logicalController) {
        if (logicalController == null) {
            throw new IllegalArgumentException("Logical controller is required");
        }
        return logicalController.ordinal();
    }

    /** Haptic APIs take the same logical controller and map it back once. */
    public static ControllerType hapticController(ControllerType logicalController) {
        if (logicalController == null) {
            throw new IllegalArgumentException("Logical controller is required");
        }
        return logicalController;
    }
}
