package org.questcraft.veq.client.input;

import net.minecraft.world.InteractionHand;
import org.vivecraft.client_vr.provider.ControllerType;

public final class QuestHandMappingSelfTest {
    private QuestHandMappingSelfTest() {
    }

    public static void main(String[] args) {
        verifyRow(ControllerType.RIGHT, false, ControllerType.RIGHT,
                InteractionHand.MAIN_HAND, 0, ControllerType.RIGHT);
        verifyRow(ControllerType.LEFT, false, ControllerType.LEFT,
                InteractionHand.OFF_HAND, 1, ControllerType.LEFT);
        verifyRow(ControllerType.RIGHT, true, ControllerType.LEFT,
                InteractionHand.OFF_HAND, 1, ControllerType.RIGHT);
        verifyRow(ControllerType.LEFT, true, ControllerType.RIGHT,
                InteractionHand.MAIN_HAND, 0, ControllerType.LEFT);
        RightBActionOriginSelfTest.runAll();
    }

    private static void verifyRow(
            ControllerType physical,
            boolean reverseHands,
            ControllerType expectedLogical,
            InteractionHand expectedHand,
            int expectedPose,
            ControllerType expectedPhysicalHaptic
    ) {
        ControllerType logical = QuestHandMapping.logicalFromPhysical(physical, reverseHands);
        require(logical == expectedLogical, "logical mapping");
        require(QuestHandMapping.interactionHand(logical) == expectedHand, "gameplay hand mapping");
        require(QuestHandMapping.poseIndex(logical) == expectedPose, "pose index mapping");
        ControllerType logicalHaptic = QuestHandMapping.hapticController(logical);
        require(QuestHandMapping.physicalFromLogical(logicalHaptic, reverseHands) == expectedPhysicalHaptic,
                "haptic round trip");
    }

    private static void require(boolean condition, String message) {
        if (!condition) {
            throw new AssertionError(message);
        }
    }
}
