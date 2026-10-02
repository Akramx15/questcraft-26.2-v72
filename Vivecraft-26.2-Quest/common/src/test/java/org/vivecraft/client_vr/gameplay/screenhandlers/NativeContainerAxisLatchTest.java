package org.vivecraft.client_vr.gameplay.screenhandlers;

import org.junit.jupiter.api.Assertions;
import org.junit.jupiter.api.Test;

class NativeContainerAxisLatchTest {
    @Test
    void suppressesAcrossCloseUntilAxisIsNeutral() {
        NativeContainerAxisLatch latch = new NativeContainerAxisLatch();

        Assertions.assertFalse(latch.update(false, true, true));
        Assertions.assertFalse(latch.transitioned());

        Assertions.assertTrue(latch.update(true, false, true));
        Assertions.assertTrue(latch.transitioned());
        Assertions.assertTrue(latch.entered());
        Assertions.assertFalse(latch.guiScrollWasNeutral());
        Assertions.assertTrue(latch.update(true, false, true));
        Assertions.assertFalse(latch.transitioned());

        // The transition frame cannot release the latch, even if OpenXR
        // transiently reports the newly active world axis as neutral.
        Assertions.assertTrue(latch.update(false, true, true));
        Assertions.assertTrue(latch.transitioned());
        Assertions.assertTrue(latch.exited());
        Assertions.assertTrue(latch.update(false, true, true));
        Assertions.assertFalse(latch.transitioned());

        // A later deflected sample resets the neutral window.
        Assertions.assertTrue(latch.update(false, true, false));
        Assertions.assertTrue(latch.update(false, true, true));
        Assertions.assertFalse(latch.update(false, true, true));
        Assertions.assertFalse(latch.transitioned());
    }

    @Test
    void suspendPreservesSuppressionAcrossHomeAndResume() {
        NativeContainerAxisLatch latch = new NativeContainerAxisLatch();
        Assertions.assertTrue(latch.update(true, false, true));

        latch.suspend();
        Assertions.assertTrue(latch.isSuppressed());
        Assertions.assertFalse(latch.transitioned());

        // The container closed while OpenXR was suspended. Resume still
        // requires an explicit neutral handoff.
        Assertions.assertTrue(latch.update(false, true, false));
        Assertions.assertTrue(latch.exited());
        Assertions.assertTrue(latch.update(false, true, true));
        Assertions.assertFalse(latch.update(false, true, true));
    }

    @Test
    void resetClearsStateForProviderDestruction() {
        NativeContainerAxisLatch latch = new NativeContainerAxisLatch();
        Assertions.assertTrue(latch.update(true, false, true));

        latch.reset();

        Assertions.assertFalse(latch.update(false, true, true));
        Assertions.assertFalse(latch.transitioned());
    }

    @Test
    void neutralGuiAxisStillWaitsPastTheTransitionFrame() {
        NativeContainerAxisLatch latch = new NativeContainerAxisLatch();
        Assertions.assertTrue(latch.update(true, true, true));
        Assertions.assertTrue(latch.guiScrollWasNeutral());

        Assertions.assertTrue(latch.update(false, true, true));
        Assertions.assertTrue(latch.update(false, true, true));
        Assertions.assertFalse(latch.update(false, true, true));
    }
}
