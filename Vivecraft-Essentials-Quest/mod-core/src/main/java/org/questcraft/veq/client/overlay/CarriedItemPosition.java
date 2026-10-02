package org.questcraft.veq.client.overlay;

/** Keeps Vanilla's 16px carried icon fully visible on an external surface. */
final class CarriedItemPosition {
    private static final int HALF_ITEM_SIZE = 8;

    private CarriedItemPosition() {
    }

    static int clamp(int coordinate, int visibleOrigin, int visibleExtent) {
        if (visibleExtent <= 0) {
            return coordinate;
        }
        int margin = Math.min(HALF_ITEM_SIZE, visibleExtent / 2);
        int minimum = visibleOrigin + margin;
        int maximum = visibleOrigin + visibleExtent - margin;
        return Math.max(minimum, Math.min(maximum, coordinate));
    }
}
