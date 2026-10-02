package org.questcraft.veq.client.input;

import org.vivecraft.client_vr.provider.ControllerType;

public final class GripReleaseLatchSelfTest {
    private GripReleaseLatchSelfTest() {
    }

    public static void main(String[] args) {
        for (String exit : new String[]{"apply", "cancel", "reset-then-apply"}) {
            GripReleaseLatch latch = new GripReleaseLatch();
            latch.suppressBoth();
            latch.observe(ControllerType.LEFT, GripReleaseLatch.Sample.DOWN);
            require(latch.isSuppressed(ControllerType.LEFT), exit + " held Grip cannot open radial");
            latch.observe(ControllerType.LEFT, GripReleaseLatch.Sample.UNKNOWN);
            require(latch.isSuppressed(ControllerType.LEFT), exit + " inactive set cannot fake release");
            latch.observe(ControllerType.LEFT, GripReleaseLatch.Sample.RELEASED);
            require(!latch.isSuppressed(ControllerType.LEFT), exit + " confirmed release rearms Grip");
            require(latch.isSuppressed(ControllerType.RIGHT), "controllers rearm independently");
            latch.observe(ControllerType.RIGHT, GripReleaseLatch.Sample.RELEASED);
            require(!latch.isSuppressed(ControllerType.RIGHT), "right confirmed release rearms");
        }
    }

    private static void require(boolean condition, String message) {
        if (!condition) {
            throw new AssertionError(message);
        }
    }
}
