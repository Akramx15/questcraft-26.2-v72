package org.questcraft.veq.client.radial;

import org.vivecraft.client_vr.provider.ControllerType;

/**
 * One-shot bridge from inventory reconciliation at tick HEAD to Grip feedback
 * at Fabric END. The event is semantic and never expires on wall-clock time.
 */
final class GripSwapRejectionHandoff {
    private ControllerType controller;
    private int slot = -1;

    void reconciled(
            PendingSwapConfirmation.Result result,
            ControllerType controller,
            int slot
    ) {
        if (result == PendingSwapConfirmation.Result.REJECTED && controller != null &&
                slot >= 0 && slot < HotbarGridLayout.SLOT_COUNT) {
            this.controller = controller;
            this.slot = slot;
            return;
        }
        if (result == PendingSwapConfirmation.Result.CONFIRMED ||
                result == PendingSwapConfirmation.Result.REJECTED) {
            clear();
        }
    }

    Rejection consume() {
        if (this.controller == null || this.slot < 0) {
            return null;
        }
        Rejection rejection = new Rejection(this.controller, this.slot);
        clear();
        return rejection;
    }

    void clear() {
        this.controller = null;
        this.slot = -1;
    }

    record Rejection(ControllerType controller, int slot) {
    }
}
