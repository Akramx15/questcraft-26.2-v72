package org.vivecraft.client_vr.gameplay.screenhandlers;

import org.junit.jupiter.api.Assertions;
import org.junit.jupiter.api.Test;

class NativeContainerFreshPressLatchTest {
    private static final int RIGHT = 1;
    private static final int LEFT = 2;

    @Test
    void requiresAnActiveNeutralSampleBeforeFreshPress() {
        NativeContainerFreshPressLatch<Object> latch = new NativeContainerFreshPressLatch<>();
        Object trigger = new Object();
        latch.arm(trigger, RIGHT);

        Assertions.assertTrue(latch.suppressUntilReleased(trigger, RIGHT, false, false),
            "an inactive action set is not evidence of physical release");
        Assertions.assertTrue(latch.suppressUntilReleased(trigger, RIGHT, true, true),
            "the held input remains suppressed after the container closes");
        Assertions.assertTrue(latch.suppressUntilReleased(trigger, RIGHT, true, false),
            "the first active neutral sample may be an action-set transition artifact");
        Assertions.assertFalse(latch.suppressUntilReleased(trigger, RIGHT, true, false),
            "two consecutive active neutral samples disarm the old press");
        Assertions.assertFalse(latch.suppressUntilReleased(trigger, RIGHT, true, true),
            "the next physical edge is fresh and may route normally");
    }

    @Test
    void tracksHandedSlotsIndependently() {
        NativeContainerFreshPressLatch<Object> latch = new NativeContainerFreshPressLatch<>();
        Object use = new Object();
        latch.arm(use, RIGHT | LEFT);

        Assertions.assertTrue(latch.suppressUntilReleased(use, RIGHT, true, false));
        Assertions.assertFalse(latch.suppressUntilReleased(use, RIGHT, true, false));
        Assertions.assertFalse(latch.isWaiting(use, RIGHT));
        Assertions.assertTrue(latch.isWaiting(use, LEFT));
        Assertions.assertTrue(latch.suppressUntilReleased(use, LEFT, true, true));
        Assertions.assertTrue(latch.suppressUntilReleased(use, LEFT, true, false));
        Assertions.assertFalse(latch.suppressUntilReleased(use, LEFT, true, false));
        Assertions.assertFalse(latch.isWaiting(use, LEFT));
    }

    @Test
    void transientNeutralCannotTurnAHeldInputIntoAFreshEdge() {
        NativeContainerFreshPressLatch<Object> latch = new NativeContainerFreshPressLatch<>();
        Object attack = new Object();
        latch.arm(attack, RIGHT);

        Assertions.assertTrue(latch.suppressUntilReleased(attack, RIGHT, true, false));
        Assertions.assertTrue(latch.suppressUntilReleased(attack, RIGHT, true, true),
            "a held input after one transient neutral sample must remain suppressed");
        Assertions.assertTrue(latch.suppressUntilReleased(attack, RIGHT, true, false));
        Assertions.assertFalse(latch.suppressUntilReleased(attack, RIGHT, true, false));
        Assertions.assertFalse(latch.suppressUntilReleased(attack, RIGHT, true, true));
    }

    @Test
    void usesIdentityRatherThanEqualsForActionKeys() {
        NativeContainerFreshPressLatch<String> latch = new NativeContainerFreshPressLatch<>();
        String first = new String("same");
        String second = new String("same");
        latch.arm(first, RIGHT);

        Assertions.assertTrue(latch.suppressUntilReleased(first, RIGHT, true, true));
        Assertions.assertFalse(latch.suppressUntilReleased(second, RIGHT, true, true));
    }
}
