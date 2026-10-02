package org.questcraft.veq.client.radial;

import org.vivecraft.client_vr.provider.ControllerType;

/** Keeps passive LEFT reconciliation from becoming a global Grip lock. */
final class GripSelectionAdmission {
    private GripSelectionAdmission() {
    }

    static boolean blockedByPendingLeftSwap(
            ControllerType controller,
            boolean leftSwapPending
    ) {
        return leftSwapPending && controller == ControllerType.LEFT;
    }
}
