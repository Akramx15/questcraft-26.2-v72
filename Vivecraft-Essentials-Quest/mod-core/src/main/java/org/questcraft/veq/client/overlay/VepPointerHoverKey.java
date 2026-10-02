package org.questcraft.veq.client.overlay;

/** Allocation-free conservative hover identity for opaque hosted screens. */
final class VepPointerHoverKey {
    private static final int VALID_MARKER = 0x4000_0000;
    private static final int COORDINATE_MASK = 0x7FFF;

    private VepPointerHoverKey() {
    }

    static int logicalPixel(double x, double y) {
        if (!Double.isFinite(x) || !Double.isFinite(y) || x < 0.0D || y < 0.0D) {
            return -1;
        }
        int pixelX = clampedFloor(x);
        int pixelY = clampedFloor(y);
        return VALID_MARKER | (pixelY << 15) | pixelX;
    }

    private static int clampedFloor(double coordinate) {
        return (int) Math.min(Math.floor(coordinate), COORDINATE_MASK);
    }
}
