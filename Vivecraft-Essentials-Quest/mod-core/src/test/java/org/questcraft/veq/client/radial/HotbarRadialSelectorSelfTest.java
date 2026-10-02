package org.questcraft.veq.client.radial;

public final class HotbarRadialSelectorSelfTest {
    private HotbarRadialSelectorSelfTest() {
    }

    public static void main(String[] args) {
        require(close(HotbarRadialSelector.CENTER_RADIUS / HotbarRadialSelector.SURFACE_SIZE, 0.08D),
                "center deadzone is eight percent of the surface width");
        require(close(HotbarRadialSelector.HYSTERESIS_RADIUS / HotbarRadialSelector.SURFACE_SIZE, 0.04D),
                "radial hysteresis is four percent of the surface width");
        require(HotbarRadialSelector.select(0.0D, 0.0D, -1) == 0, "center");
        require(HotbarRadialSelector.select(0.0D, -36.0D, -1) == 1, "top");
        require(HotbarRadialSelector.select(36.0D, -36.0D, -1) == 2, "top right");
        require(HotbarRadialSelector.select(36.0D, 0.0D, -1) == 3, "right");
        require(HotbarRadialSelector.select(36.0D, 36.0D, -1) == 4, "bottom right");
        require(HotbarRadialSelector.select(0.0D, 36.0D, -1) == 5, "bottom");
        require(HotbarRadialSelector.select(-36.0D, 36.0D, -1) == 6, "bottom left");
        require(HotbarRadialSelector.select(-36.0D, 0.0D, -1) == 7, "left");
        require(HotbarRadialSelector.select(-36.0D, -36.0D, -1) == 8, "top left");

        require(HotbarRadialSelector.select(11.0D, 0.0D, 0) == 0,
                "center sticks four percent beyond its normal radius");
        require(HotbarRadialSelector.select(5.0D, 0.0D, 3) == 3,
                "outer slice sticks four percent into center");
        double angle = Math.toRadians(27.0D);
        require(HotbarRadialSelector.select(
                Math.cos(angle) * 36.0D,
                Math.sin(angle) * 36.0D,
                3
        ) == 3, "seven-degree angular hysteresis avoids edge flicker");
        require(HotbarRadialSelector.select(Double.NaN, 0.0D, -1) == -1,
                "invalid ray selects nothing");
    }

    private static boolean close(double actual, double expected) {
        return Math.abs(actual - expected) < 1.0E-9D;
    }

    private static void require(boolean condition, String message) {
        if (!condition) {
            throw new AssertionError(message);
        }
    }
}
