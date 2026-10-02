/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */
package org.questcraft.veq.client.radial;

/**
 * Pixel contract for the compact Visor-style Grip overlay.
 *
 * <p>The backing image is exactly 98x98. Slot zero is centered and slots one
 * through eight continue clockwise from the top. Item coordinates deliberately
 * match the original Visor overlay so controller motion and visual feedback do
 * not change when the rendering backend is Vivecraft.</p>
 */
public final class HotbarGridLayout {
    public static final int PANEL_SIZE = 98;
    public static final int ITEM_SIZE = 16;
    public static final int SELECTION_SIZE = 26;
    public static final int SELECTION_INSET = 5;
    public static final int SLOT_COUNT = 9;

    private static final int[] ITEM_X = {41, 41, 77, 77, 77, 41, 5, 5, 5};
    private static final int[] ITEM_Y = {41, 5, 5, 41, 77, 77, 77, 41, 5};

    private HotbarGridLayout() {
    }

    public static int panelLeft(int screenWidth) {
        return (screenWidth - PANEL_SIZE) / 2;
    }

    public static int panelTop(int screenHeight) {
        return (screenHeight - PANEL_SIZE) / 2;
    }

    public static int itemX(int screenWidth, int slot) {
        requireSlot(slot);
        return panelLeft(screenWidth) + ITEM_X[slot];
    }

    public static int itemY(int screenHeight, int slot) {
        requireSlot(slot);
        return panelTop(screenHeight) + ITEM_Y[slot];
    }

    public static int selectionX(int screenWidth, int slot) {
        return itemX(screenWidth, slot) - SELECTION_INSET;
    }

    public static int selectionY(int screenHeight, int slot) {
        return itemY(screenHeight, slot) - SELECTION_INSET;
    }

    private static void requireSlot(int slot) {
        if (slot < 0 || slot >= SLOT_COUNT) {
            throw new IllegalArgumentException("Hotbar slot must be in [0, 8]: " + slot);
        }
    }
}
