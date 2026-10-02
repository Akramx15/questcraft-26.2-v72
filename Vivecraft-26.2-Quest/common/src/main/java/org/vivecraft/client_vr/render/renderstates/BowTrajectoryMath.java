package org.vivecraft.client_vr.render.renderstates;

/**
 * Allocation-free center-line prediction for a vanilla arrow in air.
 *
 * <p>The random launch inaccuracy and collisions are intentionally outside
 * this primitive. The caller owns and reuses the output arrays, so sampling a
 * moving VR bow does not create a new point list every rendered frame.</p>
 */
public final class BowTrajectoryMath {
    public static final double AIR_DRAG = 0.99D;
    public static final double GRAVITY_PER_TICK = 0.05D;
    public static final double VANILLA_BOW_SPEED = 3.0D;

    private BowTrajectoryMath() {
    }

    public static float vanillaPowerForTicks(int useTicks) {
        float time = Math.max(0, useTicks) / 20.0F;
        return Math.min((time * time + time * 2.0F) / 3.0F, 1.0F);
    }

    public static double launchSpeed(float vanillaPower, float physicalDraw, boolean vivecraftServer) {
        double speed = VANILLA_BOW_SPEED * clamp01(vanillaPower);
        return vivecraftServer ? speed * clamp01(physicalDraw) : speed;
    }

    /**
     * Samples the same move, air-drag, then gravity order used by
     * {@code AbstractArrow#tick}. Point zero is the launch position.
     *
     * @return the number of points written
     */
    public static int sampleAirCenterline(
        double startX, double startY, double startZ,
        double velocityX, double velocityY, double velocityZ,
        double[] pointsX, double[] pointsY, double[] pointsZ,
        int requestedPoints
    ) {
        int count = Math.min(requestedPoints,
            Math.min(pointsX.length, Math.min(pointsY.length, pointsZ.length)));
        if (count <= 0) {
            return 0;
        }

        double x = startX;
        double y = startY;
        double z = startZ;
        double dx = velocityX;
        double dy = velocityY;
        double dz = velocityZ;

        pointsX[0] = x;
        pointsY[0] = y;
        pointsZ[0] = z;
        for (int i = 1; i < count; i++) {
            x += dx;
            y += dy;
            z += dz;
            pointsX[i] = x;
            pointsY[i] = y;
            pointsZ[i] = z;

            dx *= AIR_DRAG;
            dy = dy * AIR_DRAG - GRAVITY_PER_TICK;
            dz *= AIR_DRAG;
        }
        return count;
    }

    private static float clamp01(float value) {
        if (!Float.isFinite(value)) {
            return 0.0F;
        }
        return Math.max(0.0F, Math.min(value, 1.0F));
    }
}
