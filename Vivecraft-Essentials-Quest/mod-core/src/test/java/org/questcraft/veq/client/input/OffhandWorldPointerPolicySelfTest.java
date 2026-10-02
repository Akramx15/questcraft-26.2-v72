package org.questcraft.veq.client.input;

public final class OffhandWorldPointerPolicySelfTest {
    private OffhandWorldPointerPolicySelfTest() {
    }

    public static void main(String[] args) {
        require(show(true, true, true, true, true, false, false, false,
                false, false, false, false, false, true),
                "clean left-world state renders");
        for (int disabledGate = 0; disabledGate < 5; disabledGate++) {
            boolean[] required = {true, true, true, true, true};
            required[disabledGate] = false;
            require(!show(required[0], required[1], required[2], required[3], required[4],
                    false, false, false, false, false, false, false, false, true),
                    "every positive gate fails closed: " + disabledGate);
        }
        for (int ownershipGate = 0; ownershipGate < 8; ownershipGate++) {
            boolean[] blockers = new boolean[8];
            blockers[ownershipGate] = true;
            require(!show(true, true, true, true, true,
                    blockers[0], blockers[1], blockers[2], blockers[3],
                    blockers[4], blockers[5], blockers[6], blockers[7], true),
                    "every owner/lifecycle blocker hides pointer: " + ownershipGate);
        }
        require(!show(true, true, true, true, true, false, false, false,
                false, false, false, false, false, false),
                "invalid world scale hides pointer");
    }

    private static boolean show(
            boolean runtimeReady,
            boolean handWorldAllowed,
            boolean trackingValid,
            boolean settingAllows,
            boolean firstPerson,
            boolean viewOnly,
            boolean keyboard,
            boolean roomGui,
            boolean paused,
            boolean vanillaOverlay,
            boolean wrist,
            boolean grip,
            boolean teleport,
            boolean worldScale
    ) {
        return OffhandWorldPointerPolicy.shouldRender(
                runtimeReady, handWorldAllowed, trackingValid, settingAllows, firstPerson,
                viewOnly, keyboard, roomGui, paused, vanillaOverlay, wrist, grip, teleport,
                worldScale);
    }

    private static void require(boolean condition, String message) {
        if (!condition) {
            throw new AssertionError(message);
        }
    }
}
