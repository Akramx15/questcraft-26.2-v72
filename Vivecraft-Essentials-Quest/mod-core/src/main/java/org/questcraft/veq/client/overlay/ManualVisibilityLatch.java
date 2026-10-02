package org.questcraft.veq.client.overlay;

/** Bounded VEP-style force-visible state for a key/quick-action press. */
public final class ManualVisibilityLatch {
    public static final int OPEN_TICKS = 100;

    private int remainingTicks;

    public void toggle(boolean pressEvent, boolean canOpen) {
        if (!pressEvent) {
            return;
        }
        if (remainingTicks > 0) {
            remainingTicks = 0;
        } else if (canOpen) {
            remainingTicks = OPEN_TICKS;
        }
    }

    public void tick(boolean stillValid) {
        if (!stillValid) {
            remainingTicks = 0;
        } else if (remainingTicks > 0) {
            remainingTicks--;
        }
    }

    public boolean forcesVisible() {
        return remainingTicks > 0;
    }

    public int remainingTicks() {
        return remainingTicks;
    }

    public void clear() {
        remainingTicks = 0;
    }
}
