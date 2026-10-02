package org.questcraft.veq.client.gui;

/** Host-only regression coverage for the original VEP compact layout. */
public final class VepInventoryLayoutSelfTest {
    private VepInventoryLayoutSelfTest() {
    }

    public static void main(String[] args) {
        requirePosition(VepInventoryLayout.hotbar(0), 121, 38, "selected hotbar center");
        int[][] clockwise = {
                {121, 11}, {148, 11}, {148, 38}, {148, 65},
                {121, 65}, {94, 65}, {94, 38}, {94, 11}
        };
        for (int slot = 1; slot <= 8; slot++) {
            requirePosition(
                    VepInventoryLayout.hotbar(slot),
                    clockwise[slot - 1][0],
                    clockwise[slot - 1][1],
                    "clockwise hotbar " + slot
            );
        }
        requirePosition(VepInventoryLayout.inventory(9), 49, 96, "inventory first");
        requirePosition(VepInventoryLayout.inventory(35), 193, 132, "inventory last");
        requirePosition(VepInventoryLayout.crafting(3), 199, 44, "crafting lower right");
        requirePosition(VepInventoryLayout.result(), 237, 36, "crafting result");
        requirePosition(VepInventoryLayout.armor(36), 8, 62, "boots");
        requirePosition(VepInventoryLayout.armor(39), 8, 8, "helmet");
        requirePosition(VepInventoryLayout.offhand(), 76, 62, "offhand");
        requirePosition(VepInventoryLayout.quickAction(0), 20, 90, "quick action inner left");
        requirePosition(VepInventoryLayout.quickAction(11), 240, 134, "quick action outer right");
        System.out.println("VepInventoryLayoutSelfTest PASS");
    }

    private static void requirePosition(VepInventoryLayout.Position actual,
                                        int expectedX,
                                        int expectedY,
                                        String message) {
        if (actual.x() != expectedX || actual.y() != expectedY) {
            throw new AssertionError(
                    message + ": expected=" + expectedX + "," + expectedY
                            + " actual=" + actual.x() + "," + actual.y()
            );
        }
    }
}
