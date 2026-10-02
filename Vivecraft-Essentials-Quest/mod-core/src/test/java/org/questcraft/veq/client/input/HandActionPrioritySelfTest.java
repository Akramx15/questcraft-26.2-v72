package org.questcraft.veq.client.input;

import org.vivecraft.client_vr.settings.VRSettings;

public final class HandActionPrioritySelfTest {
    private HandActionPrioritySelfTest() {
    }

    public static void main(String[] args) {
        require(HandActionPriority.choose(true, true, true, true, true) ==
                HandActionPriority.Owner.WRIST, "wrist wins every conflict");
        require(HandActionPriority.choose(false, true, true, true, true) ==
                HandActionPriority.Owner.TRACKER, "two-hand tracker wins after wrist");
        require(HandActionPriority.choose(false, false, true, true, true) ==
                HandActionPriority.Owner.IMMERSIVE, "immersive wins over climb and Grip");
        require(HandActionPriority.choose(false, false, false, true, true) ==
                HandActionPriority.Owner.CLIMBING, "climbing wins over Grip");
        require(HandActionPriority.choose(false, false, false, false, true) ==
                HandActionPriority.Owner.GRIP, "same-hand Grip wins over world");
        require(HandActionPriority.choose(false, false, false, false, false) ==
                HandActionPriority.Owner.WORLD, "world is final owner");

        require(HandActionContext.useDelay(VRSettings.RightClickDelay.VANILLA) == 4, "vanilla cooldown");
        require(HandActionContext.useDelay(VRSettings.RightClickDelay.SLOW) == 6, "slow cooldown");
        require(HandActionContext.useDelay(VRSettings.RightClickDelay.SLOWER) == 8, "slower cooldown");
        require(HandActionContext.useDelay(VRSettings.RightClickDelay.SLOWEST) == 10, "slowest cooldown");
    }

    private static void require(boolean condition, String message) {
        if (!condition) {
            throw new AssertionError(message);
        }
    }
}
