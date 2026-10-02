package org.questcraft.veq.client.wrist;

import org.vivecraft.client_vr.provider.ControllerType;

/** Pure priority policy shared by wrist runtime and host self-tests. */
public final class WristInputOwnership {
    private WristInputOwnership() {
    }

    public static boolean ownsController(
            boolean showing,
            boolean hasView,
            boolean calibrating,
            ControllerType controller,
            boolean pointerFocusedOrDragging
    ) {
        if (!showing || !hasView || controller == null) {
            return false;
        }
        // Calibration intentionally owns both controllers. Normal wrist use
        // owns only the hand whose pointer is focused or has an accepted drag;
        // a carried stack by itself never captures the anchor/other hand.
        return calibrating || pointerFocusedOrDragging;
    }
}
