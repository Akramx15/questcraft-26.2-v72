package org.vivecraft.client_vr.gameplay.trackers;

import org.junit.jupiter.api.Assertions;
import org.junit.jupiter.api.Test;

class BowNockMathTest {
    @Test
    void entersAtQuestDistanceAndAngle() {
        Assertions.assertTrue(BowNockMath.isWithinGate(0.179, 1.0F, cosine(29.9F), false));
        Assertions.assertFalse(BowNockMath.isWithinGate(0.181, 1.0F, cosine(29.9F), false));
        Assertions.assertFalse(BowNockMath.isWithinGate(0.179, 1.0F, cosine(30.1F), false));
    }

    @Test
    void spatialHysteresisKeepsAnExistingNockStable() {
        Assertions.assertTrue(BowNockMath.isWithinGate(0.205, 1.0F, cosine(37.9F), true));
        Assertions.assertFalse(BowNockMath.isWithinGate(0.215, 1.0F, cosine(37.9F), true));
        Assertions.assertFalse(BowNockMath.isWithinGate(0.205, 1.0F, cosine(38.1F), true));
    }

    @Test
    void scalesDistanceAndRejectsInvalidSamples() {
        Assertions.assertTrue(BowNockMath.isWithinGate(0.359, 2.0F, 1.0F, false));
        Assertions.assertFalse(BowNockMath.isWithinGate(0.361, 2.0F, 1.0F, false));
        Assertions.assertFalse(BowNockMath.isWithinGate(Double.NaN, 1.0F, 1.0F, false));
        Assertions.assertFalse(BowNockMath.isWithinGate(0.1, 0.0F, 1.0F, false));
        Assertions.assertFalse(BowNockMath.isWithinGate(0.1, 1.0F, Float.NaN, false));
    }

    @Test
    void angleCalculationClampsRoundoff() {
        Assertions.assertEquals(0.0, BowNockMath.angleDegrees(1.00001F), 1.0E-6);
        Assertions.assertEquals(180.0, BowNockMath.angleDegrees(-1.00001F), 1.0E-6);
        Assertions.assertTrue(Double.isNaN(BowNockMath.angleDegrees(Float.NaN)));
    }

    private static float cosine(float degrees) {
        return (float) Math.cos(Math.toRadians(degrees));
    }
}
