package org.questcraft.veq.client.overlay;

/** Host-only VEP manual-latch duration, toggle and invalidation contracts. */
public final class ManualVisibilityLatchSelfTest {
    private ManualVisibilityLatchSelfTest() {
    }

    public static void main(String[] args) {
        ManualVisibilityLatch latch = new ManualVisibilityLatch();
        latch.toggle(false, true);
        require(!latch.forcesVisible(), "release event opened the latch");
        latch.toggle(true, false);
        require(!latch.forcesVisible(), "invalid gameplay state opened the latch");

        latch.toggle(true, true);
        require(latch.remainingTicks() == ManualVisibilityLatch.OPEN_TICKS,
                "press did not start the bounded window");
        for (int tick = 1; tick < ManualVisibilityLatch.OPEN_TICKS; tick++) {
            latch.tick(true);
            require(latch.forcesVisible(), "window closed one tick early");
        }
        latch.tick(true);
        require(!latch.forcesVisible(), "window exceeded its duration");

        latch.toggle(true, true);
        latch.toggle(true, true);
        require(!latch.forcesVisible(), "second press must close a manual latch");
        latch.toggle(true, true);
        latch.tick(false);
        require(!latch.forcesVisible(), "invalid lifecycle state did not clear latch");

        System.out.println("ManualVisibilityLatchSelfTest PASS");
    }

    private static void require(boolean condition, String message) {
        if (!condition) {
            throw new AssertionError(message);
        }
    }
}
