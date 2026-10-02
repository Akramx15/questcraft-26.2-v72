package org.vmstudio.essentials.core.client.gui.overlays;

public final class ManualVisibilityLatchSelfTest {
    private ManualVisibilityLatchSelfTest() {
    }

    public static void main(String[] args) {
        ManualVisibilityLatch latch = new ManualVisibilityLatch();
        latch.onQuickAction(false, true);
        require(!latch.forcesVisible(), "release must not open the wrist UI");

        latch.onQuickAction(true, true);
        require(latch.forcesVisible(), "press must open the wrist UI");
        latch.onQuickAction(false, true);
        require(latch.forcesVisible(), "matching release must not toggle it closed");

        for (int tick = 0; tick < ManualVisibilityLatch.OPEN_TICKS; tick++) {
            latch.tick(true);
        }
        require(!latch.forcesVisible(), "force-visible acquisition window must expire");

        latch.onQuickAction(true, true);
        latch.tick(false);
        require(!latch.forcesVisible(), "invalid gameplay state must clear the latch");

        latch.onQuickAction(true, false);
        require(!latch.forcesVisible(), "invalid gameplay state must not open the wrist UI");

        latch.onQuickAction(true, true);
        latch.onQuickAction(true, true);
        require(!latch.forcesVisible(), "a second press must cancel the acquisition window");
    }

    private static void require(boolean condition, String message) {
        if (!condition) {
            throw new AssertionError(message);
        }
    }
}
