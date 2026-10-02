package org.questcraft.veq.client.overlay;

import org.vivecraft.client_vr.provider.ControllerType;

public final class WristHeldItemRenderPolicySelfTest {
    private WristHeldItemRenderPolicySelfTest() {
    }

    public static void main(String[] args) {
        require(WristHeldItemRenderPolicy.shouldHide(
                true, ControllerType.LEFT, ControllerType.LEFT, true),
            "a visible wrist hides a shield in its anchor hand");
        require(!WristHeldItemRenderPolicy.shouldHide(
                false, ControllerType.LEFT, ControllerType.LEFT, true),
            "the shield returns as soon as the wrist hides");
        require(!WristHeldItemRenderPolicy.shouldHide(
                true, ControllerType.LEFT, ControllerType.RIGHT, true),
            "the opposite-hand shield remains visible");
        require(!WristHeldItemRenderPolicy.shouldHide(
                true, ControllerType.LEFT, ControllerType.LEFT, false),
            "non-shield held items remain visible");
    }

    private static void require(boolean condition, String message) {
        if (!condition) {
            throw new AssertionError(message);
        }
    }
}
