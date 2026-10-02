package org.questcraft.veq.client.radial;

import org.vivecraft.client_vr.provider.ControllerType;

/** Host contract for two simultaneously visible, no-queue Grip surfaces. */
public final class GripDualSurfaceSessionSelfTest {
    private GripDualSurfaceSessionSelfTest() {
    }

    public static void main(String[] args) {
        GripSurfaceSession right = new GripSurfaceSession(ControllerType.RIGHT);
        GripSurfaceSession left = new GripSurfaceSession(ControllerType.LEFT);

        require(right.open(ControllerType.RIGHT, true), "right opens its own surface");
        require(left.open(ControllerType.LEFT, true), "left opens while right is visible");
        require(right.isShowing() && left.isShowing(),
                "both independent surfaces are simultaneously visible");
        require(right.owns(ControllerType.RIGHT) && !right.owns(ControllerType.LEFT),
                "right surface never changes logical owner");
        require(left.owns(ControllerType.LEFT) && !left.owns(ControllerType.RIGHT),
                "left surface never changes logical owner");

        right.close();
        require(!right.isShowing() && left.isShowing(),
                "closing right preserves the visible left surface");
        right.open(ControllerType.RIGHT, true);
        left.close();
        require(right.isShowing() && !left.isShowing(),
                "closing left preserves the visible right surface");

        require(!GripSelectionAdmission.blockedByPendingLeftSwap(
                        ControllerType.RIGHT, true),
                "right selection remains immediate during passive left reconciliation");
        require(GripSelectionAdmission.blockedByPendingLeftSwap(
                        ControllerType.LEFT, true),
                "a pending left transaction alone rejects a second left transaction");

        // No timestamp, cooldown, transfer queue, or two-tick latch exists in
        // an individual surface lifecycle. Reopening on the next observation
        // is always admitted when the same Grip is still physically down.
        for (int attempt = 0; attempt < 32; attempt++) {
            right.close();
            require(right.open(ControllerType.RIGHT, true),
                    "rapid right reopen has no hidden multi-tick gate");
            left.close();
            require(left.open(ControllerType.LEFT, true),
                    "rapid left reopen has no hidden multi-tick gate");
        }

        // Global lifecycle cancellation explicitly closes both owners.
        right.close();
        left.close();
        require(!right.isShowing() && !left.isShowing(),
                "pause/world/VR lifecycle cancellation closes both surfaces");

        require(!right.open(ControllerType.LEFT, true),
                "one hand cannot steal the other hand's surface");
        require(!left.open(ControllerType.LEFT, false),
                "a stale edge without held Grip fails closed");
    }

    private static void require(boolean condition, String message) {
        if (!condition) {
            throw new AssertionError(message);
        }
    }
}
