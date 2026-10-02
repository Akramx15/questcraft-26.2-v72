package org.vivecraft.client_vr.render.renderstates;

import org.junit.jupiter.api.Assertions;
import org.junit.jupiter.api.Test;

class BowTrajectoryMathTest {
    @Test
    void matchesVanillaBowPowerCurveAndVivecraftDrawMultiplier() {
        Assertions.assertEquals(0.0F, BowTrajectoryMath.vanillaPowerForTicks(0));
        Assertions.assertEquals(0.41666666F, BowTrajectoryMath.vanillaPowerForTicks(10), 1.0E-6F);
        Assertions.assertEquals(1.0F, BowTrajectoryMath.vanillaPowerForTicks(20));
        Assertions.assertEquals(1.0F, BowTrajectoryMath.vanillaPowerForTicks(200));

        Assertions.assertEquals(3.0D, BowTrajectoryMath.launchSpeed(1.0F, 0.25F, false), 1.0E-9D);
        Assertions.assertEquals(0.75D, BowTrajectoryMath.launchSpeed(1.0F, 0.25F, true), 1.0E-9D);
        Assertions.assertEquals(0.0D, BowTrajectoryMath.launchSpeed(1.0F, Float.NaN, true), 1.0E-9D);
    }

    @Test
    void samplesArrowMoveThenAirDragThenGravityIntoCallerOwnedArrays() {
        double[] x = new double[4];
        double[] y = new double[4];
        double[] z = new double[4];

        int count = BowTrajectoryMath.sampleAirCenterline(
            1.0D, 2.0D, 3.0D,
            3.0D, 0.0D, 0.0D,
            x, y, z, 3);

        Assertions.assertEquals(3, count);
        Assertions.assertArrayEquals(new double[]{1.0D, 4.0D, 6.97D, 0.0D}, x, 1.0E-9D);
        Assertions.assertArrayEquals(new double[]{2.0D, 2.0D, 1.95D, 0.0D}, y, 1.0E-9D);
        Assertions.assertArrayEquals(new double[]{3.0D, 3.0D, 3.0D, 0.0D}, z, 1.0E-9D);
    }

    @Test
    void respectsTheShortestReusableBufferAndEmptyRequests() {
        double[] x = new double[4];
        double[] y = new double[2];
        double[] z = new double[3];
        Assertions.assertEquals(2, BowTrajectoryMath.sampleAirCenterline(
            0.0D, 0.0D, 0.0D, 1.0D, 1.0D, 1.0D, x, y, z, 10));
        Assertions.assertEquals(0, BowTrajectoryMath.sampleAirCenterline(
            0.0D, 0.0D, 0.0D, 1.0D, 1.0D, 1.0D, x, y, z, 0));
    }

    @Test
    void startupOverrideParserAcceptsOnlyExplicitTrue() {
        Assertions.assertFalse(BowTrajectoryRenderState.parseEnabled(null));
        Assertions.assertFalse(BowTrajectoryRenderState.parseEnabled("false"));
        Assertions.assertTrue(BowTrajectoryRenderState.parseEnabled("true"));
    }

    @Test
    void energyGradientMovesFromGoldToCyanAndPulseBrightensIt() {
        Assertions.assertEquals(255, BowTrajectoryRenderState.energyChannel(255, 64, 0.0F, 0.0F));
        Assertions.assertEquals(64, BowTrajectoryRenderState.energyChannel(255, 64, 1.0F, 0.0F));
        Assertions.assertEquals(255, BowTrajectoryRenderState.energyChannel(255, 64, 1.0F, 1.0F));
        Assertions.assertEquals(1.0F, BowTrajectoryRenderState.pulseStrength(0.5F, 0.5F));
        Assertions.assertEquals(0.0F, BowTrajectoryRenderState.pulseStrength(0.0F, 0.5F));
    }
}
