package org.vivecraft.client_vr.provider.openxr;

import org.junit.jupiter.api.Assertions;
import org.junit.jupiter.api.Test;
import org.vivecraft.client_vr.provider.ControllerType;

class OpenXRHandednessTest {
    @Test
    void logicalToPhysicalMappingDoesNotAlternateAcrossFrames() {
        for (int frame = 0; frame < 120; frame++) {
            Assertions.assertEquals(1, OpenXRHandedness.physicalIndex(0, true));
            Assertions.assertEquals(0, OpenXRHandedness.physicalIndex(1, true));
        }
        Assertions.assertEquals(0, OpenXRHandedness.physicalIndex(0, false));
        Assertions.assertEquals(1, OpenXRHandedness.physicalIndex(1, false));
    }

    @Test
    void physicalOriginsBecomeLogicalControllersExactlyOnce() {
        Assertions.assertEquals(
            ControllerType.LEFT, OpenXRHandedness.logicalController(ControllerType.RIGHT, true));
        Assertions.assertEquals(
            ControllerType.RIGHT, OpenXRHandedness.logicalController(ControllerType.LEFT, true));
        Assertions.assertEquals(
            ControllerType.RIGHT, OpenXRHandedness.logicalController(ControllerType.RIGHT, false));
        Assertions.assertNull(OpenXRHandedness.logicalController(null, true));
    }

    @Test
    void externalSecondaryFaceButtonsFollowTheLogicalPointerHand() {
        Assertions.assertEquals(ControllerType.RIGHT,
            OpenXRHandedness.logicalController(ControllerType.RIGHT, false),
            "physical right A routes to logical right by default");
        Assertions.assertEquals(ControllerType.LEFT,
            OpenXRHandedness.logicalController(ControllerType.LEFT, false),
            "physical left X routes to logical left by default");
        Assertions.assertEquals(ControllerType.LEFT,
            OpenXRHandedness.logicalController(ControllerType.RIGHT, true),
            "reverseHands makes physical right A own logical left");
        Assertions.assertEquals(ControllerType.RIGHT,
            OpenXRHandedness.logicalController(ControllerType.LEFT, true),
            "reverseHands makes physical left X own logical right");
    }

    @Test
    void physicalLogicalTableIsBijectiveForBothReverseModes() {
        ControllerType[] physicalHands = {ControllerType.RIGHT, ControllerType.LEFT};
        for (boolean reverseHands : new boolean[]{false, true}) {
            for (ControllerType physical : physicalHands) {
                ControllerType logical = OpenXRHandedness.logicalController(physical, reverseHands);
                int physicalIndex = OpenXRHandedness.physicalIndex(logical.ordinal(), reverseHands);
                Assertions.assertEquals(physical.ordinal(), physicalIndex,
                    () -> "round trip physical=" + physical + " reverse=" + reverseHands);
                // Every consumer after the provider boundary uses this same
                // logical ordinal for pose, action, and gameplay hand.
                Assertions.assertEquals(logical.ordinal(), logical == ControllerType.RIGHT ? 0 : 1);
            }
        }
    }

    @Test
    void rejectsInvalidLogicalControllerIndices() {
        Assertions.assertThrows(
            IllegalArgumentException.class, () -> OpenXRHandedness.physicalIndex(-1, false));
        Assertions.assertThrows(
            IllegalArgumentException.class, () -> OpenXRHandedness.physicalIndex(2, false));
    }
}
