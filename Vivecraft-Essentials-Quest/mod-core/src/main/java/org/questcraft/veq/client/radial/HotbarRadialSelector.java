/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */
package org.questcraft.veq.client.radial;

/**
 * Visor-compatible center/sector selection with a sticky hysteresis margin.
 * Coordinates are measured from the 2D surface center, not from slot boxes.
 */
public final class HotbarRadialSelector {
    public static final double SURFACE_SIZE = 98.0D;
    /** Eight percent of the real 98x98 logical surface width. */
    public static final double CENTER_RADIUS = SURFACE_SIZE * 0.08D;
    public static final double HYSTERESIS_ANGLE_RADIANS = Math.toRadians(7.0D);
    /** Four percent of the real 98x98 logical surface width. */
    public static final double HYSTERESIS_RADIUS = SURFACE_SIZE * 0.04D;
    private static final double SECTOR_HALF_ANGLE = Math.PI / 8.0D;
    private static final double[] SECTOR_ANGLES = {
            0.0D,
            -Math.PI / 2.0D,
            -Math.PI / 4.0D,
            0.0D,
            Math.PI / 4.0D,
            Math.PI / 2.0D,
            3.0D * Math.PI / 4.0D,
            Math.PI,
            -3.0D * Math.PI / 4.0D
    };

    private HotbarRadialSelector() {
    }

    public static int select(double x, double y, int previousSlot) {
        if (validSlot(previousSlot) && contains(previousSlot, x, y, true)) {
            return previousSlot;
        }
        if (contains(0, x, y, false)) {
            return 0;
        }
        for (int slot = 1; slot < HotbarGridLayout.SLOT_COUNT; slot++) {
            if (contains(slot, x, y, false)) {
                return slot;
            }
        }
        return -1;
    }

    private static boolean contains(int slot, double x, double y, boolean sticky) {
        double radiusMargin = sticky ? HYSTERESIS_RADIUS : 0.0D;
        double distance = Math.hypot(x, y);
        if (slot == 0) {
            return distance <= CENTER_RADIUS + radiusMargin;
        }
        if (distance < CENTER_RADIUS - radiusMargin) {
            return false;
        }
        double angleMargin = sticky ? HYSTERESIS_ANGLE_RADIANS : 0.0D;
        double delta = wrapAngle(Math.atan2(y, x) - SECTOR_ANGLES[slot]);
        return Math.abs(delta) <= SECTOR_HALF_ANGLE + angleMargin;
    }

    private static boolean validSlot(int slot) {
        return slot >= 0 && slot < HotbarGridLayout.SLOT_COUNT;
    }

    private static double wrapAngle(double angle) {
        angle %= Math.PI * 2.0D;
        if (angle > Math.PI) {
            return angle - Math.PI * 2.0D;
        }
        if (angle < -Math.PI) {
            return angle + Math.PI * 2.0D;
        }
        return angle;
    }
}
