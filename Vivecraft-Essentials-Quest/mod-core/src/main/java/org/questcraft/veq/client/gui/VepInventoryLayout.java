package org.questcraft.veq.client.gui;

/** Pure coordinate contract for the 258x156 VEP panel. */
public final class VepInventoryLayout {
    public static final int PANEL_WIDTH = 258;
    public static final int PANEL_HEIGHT = 156;
    public static final int QUICK_ACTION_SIZE = 20;

    private static final int[] HOTBAR_X = {121, 121, 148, 148, 148, 121, 94, 94, 94};
    private static final int[] HOTBAR_Y = {38, 11, 11, 38, 65, 65, 65, 38, 11};
    private static final int[] QUICK_ACTION_COLUMN_X = {20, 218, -2, 240};

    private VepInventoryLayout() {
    }

    public static Position hotbar(int index) {
        requireRange(index, 0, 8, "hotbar");
        return new Position(HOTBAR_X[index], HOTBAR_Y[index]);
    }

    public static Position inventory(int containerIndex) {
        requireRange(containerIndex, 9, 35, "inventory");
        int index = containerIndex - 9;
        return new Position(49 + index % 9 * 18, 96 + index / 9 * 18);
    }

    public static Position armor(int containerIndex) {
        requireRange(containerIndex, 36, 39, "armor");
        return new Position(8, 62 - (containerIndex - 36) * 18);
    }

    /** Dedicated offhand slot retained by the Vivecraft port. */
    public static Position offhand() {
        return new Position(76, 62);
    }

    public static Position crafting(int index) {
        requireRange(index, 0, 3, "crafting");
        return new Position(181 + index % 2 * 18, 26 + index / 2 * 18);
    }

    public static Position result() {
        return new Position(237, 36);
    }

    public static Position quickAction(int slot) {
        requireRange(slot, 0, 11, "quick action");
        return new Position(
                QUICK_ACTION_COLUMN_X[slot / 3],
                90 + slot % 3 * 22
        );
    }

    private static void requireRange(int value, int minimum, int maximum, String name) {
        if (value < minimum || value > maximum) {
            throw new IndexOutOfBoundsException(name + " index " + value);
        }
    }

    public record Position(int x, int y) {
    }
}
