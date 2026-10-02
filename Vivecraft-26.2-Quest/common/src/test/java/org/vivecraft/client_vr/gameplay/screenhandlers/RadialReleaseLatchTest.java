package org.vivecraft.client_vr.gameplay.screenhandlers;

import org.junit.jupiter.api.Assertions;
import org.junit.jupiter.api.Test;
import org.vivecraft.client_vr.provider.ControllerType;

class RadialReleaseLatchTest {
    @Test
    void selectsOnlyOnValidatedSameHandDownToReleasedEdge() {
        for (ControllerType controller : ControllerType.values()) {
            RadialReleaseLatch latch = armed(controller);
            Assertions.assertEquals(
                RadialReleaseLatch.Decision.KEEP_OPEN,
                latch.update(controller, RadialReleaseLatch.Sample.DOWN));
            Assertions.assertEquals(
                RadialReleaseLatch.Decision.SELECT_AND_CLOSE,
                latch.update(controller, RadialReleaseLatch.Sample.RELEASED));
        }
    }

    @Test
    void actionOrOriginLossCancelsWithoutSelection() {
        for (ControllerType controller : ControllerType.values()) {
            Assertions.assertEquals(
                RadialReleaseLatch.Decision.CANCEL,
                armed(controller).update(controller, RadialReleaseLatch.Sample.UNKNOWN));

            ControllerType other = controller == ControllerType.LEFT
                ? ControllerType.RIGHT : ControllerType.LEFT;
            Assertions.assertEquals(
                RadialReleaseLatch.Decision.CANCEL,
                armed(controller).update(other, RadialReleaseLatch.Sample.RELEASED));
        }
    }

    @Test
    void disabledOrInactiveActionSamplesUnknown() {
        Assertions.assertEquals(
            RadialReleaseLatch.Sample.UNKNOWN,
            RadialReleaseLatch.sample(true, false, true, true, true, false));
        Assertions.assertEquals(
            RadialReleaseLatch.Sample.UNKNOWN,
            RadialReleaseLatch.sample(true, true, false, true, true, false));
        Assertions.assertEquals(
            RadialReleaseLatch.Sample.UNKNOWN,
            RadialReleaseLatch.sample(true, true, true, false, false, false));
        Assertions.assertEquals(
            RadialReleaseLatch.Sample.UNKNOWN,
            RadialReleaseLatch.sample(true, true, true, true, false, false));
    }

    @Test
    void releaseWithoutAnInitialDownCancels() {
        for (ControllerType controller : ControllerType.values()) {
            RadialReleaseLatch latch = new RadialReleaseLatch(controller);
            Assertions.assertEquals(
                RadialReleaseLatch.Decision.CANCEL,
                latch.update(controller, RadialReleaseLatch.Sample.RELEASED));
        }
    }

    private static RadialReleaseLatch armed(ControllerType controller) {
        RadialReleaseLatch latch = new RadialReleaseLatch(controller);
        Assertions.assertEquals(
            RadialReleaseLatch.Decision.KEEP_OPEN,
            latch.update(controller, RadialReleaseLatch.Sample.DOWN));
        return latch;
    }
}
