package org.vivecraft.client_vr.gameplay.trackers;

import net.minecraft.util.Mth;

/** Quest-friendly bow nock geometry with a small spatial hysteresis band. */
final class BowNockMath {
    static final float ENTER_DISTANCE_METERS = 0.18F;
    static final float EXIT_DISTANCE_METERS = 0.21F;
    static final float ENTER_ANGLE_DEGREES = 30.0F;
    static final float EXIT_ANGLE_DEGREES = 38.0F;

    private static final float ENTER_DOT = cosineDegrees(ENTER_ANGLE_DEGREES);
    private static final float EXIT_DOT = cosineDegrees(EXIT_ANGLE_DEGREES);

    private BowNockMath() {
    }

    static boolean isWithinGate(double notchDistance, float worldScale, float directionDot, boolean latched) {
        if (!Double.isFinite(notchDistance) || !Float.isFinite(worldScale) || !Float.isFinite(directionDot) ||
            worldScale <= 0.0F)
        {
            return false;
        }
        float distance = (latched ? EXIT_DISTANCE_METERS : ENTER_DISTANCE_METERS) * worldScale;
        float minimumDot = latched ? EXIT_DOT : ENTER_DOT;
        return notchDistance <= distance && Mth.clamp(directionDot, -1.0F, 1.0F) >= minimumDot;
    }

    static double angleDegrees(float directionDot) {
        if (!Float.isFinite(directionDot)) {
            return Double.NaN;
        }
        return Math.toDegrees(Math.acos(Mth.clamp(directionDot, -1.0F, 1.0F)));
    }

    private static float cosineDegrees(float degrees) {
        return (float) Math.cos(Math.toRadians(degrees));
    }
}
