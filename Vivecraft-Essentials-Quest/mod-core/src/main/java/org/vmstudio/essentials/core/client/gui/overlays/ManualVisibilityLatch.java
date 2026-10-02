package org.vmstudio.essentials.core.client.gui.overlays;

/** Bounded force-visible state for acquiring the wrist UI after a button press. */
final class ManualVisibilityLatch {
    static final int OPEN_TICKS = 100;

    private int remainingTicks;

    void onQuickAction(boolean pressEvent, boolean canOpen) {
        if (!pressEvent) {
            return;
        }
        if (remainingTicks > 0) {
            remainingTicks = 0;
        } else if (canOpen) {
            remainingTicks = OPEN_TICKS;
        }
    }

    void tick(boolean stillValid) {
        if (!stillValid) {
            remainingTicks = 0;
        } else if (remainingTicks > 0) {
            remainingTicks--;
        }
    }

    boolean forcesVisible() {
        return remainingTicks > 0;
    }

    void clear() {
        remainingTicks = 0;
    }
}
