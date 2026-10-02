package org.questcraft.veq.client.radial;

import org.vivecraft.client_vr.provider.ControllerType;

/** Keeps a released Grip surface read-only while transaction feedback is visible. */
final class GripFeedbackState {
    static final int REJECTION_TICKS = 4;

    private Mode mode = Mode.NONE;
    private ControllerType controller;
    private int slot = -1;
    private int ticksRemaining;

    void pending(ControllerType controller, int slot) {
        this.mode = Mode.PENDING_SWAP;
        this.controller = controller;
        this.slot = slot;
        this.ticksRemaining = 0;
    }

    void rejected(ControllerType controller, int slot) {
        this.mode = Mode.REJECTED;
        this.controller = controller;
        this.slot = slot;
        this.ticksRemaining = REJECTION_TICKS;
    }

    boolean rejectPending(ControllerType controller, int slot) {
        if (!isPending() || controller == null || this.controller != controller ||
                this.slot != slot) {
            return false;
        }
        rejected(controller, slot);
        return true;
    }

    boolean blocksSelection() {
        return this.mode != Mode.NONE;
    }

    boolean isPending() {
        return this.mode == Mode.PENDING_SWAP;
    }

    boolean isRejected() {
        return this.mode == Mode.REJECTED;
    }

    ControllerType controller() {
        return this.controller;
    }

    int slot() {
        return this.slot;
    }

    int rejectedSlot(ControllerType controller) {
        return isRejected() && controller != null && this.controller == controller
                ? this.slot
                : -1;
    }

    /** Returns true after exactly the short rejection-display window. */
    boolean tickRejected() {
        if (!isRejected()) {
            return false;
        }
        if (this.ticksRemaining > 0) {
            this.ticksRemaining--;
        }
        return this.ticksRemaining == 0;
    }

    void clear() {
        this.mode = Mode.NONE;
        this.controller = null;
        this.slot = -1;
        this.ticksRemaining = 0;
    }

    private enum Mode {
        NONE,
        PENDING_SWAP,
        REJECTED
    }
}
