package org.questcraft.veq.client.radial;

public final class HotbarGridLayoutSelfTest {
    private HotbarGridLayoutSelfTest() {
    }

    public static void main(String[] args) {
        require(HotbarGridLayout.PANEL_SIZE == 98, "panel is 98x98");
        require(HotbarGridLayout.ITEM_SIZE == 16, "vanilla items retain 16px size");
        require(HotbarGridLayout.SELECTION_SIZE == 26, "selection frame is 26px");

        int width = 400;
        int height = 300;
        int left = HotbarGridLayout.panelLeft(width);
        int top = HotbarGridLayout.panelTop(height);
        int[][] expected = {
                {41, 41}, // selected/default slot in the center
                {41, 5},  // top
                {77, 5},  // top-right
                {77, 41}, // right
                {77, 77}, // bottom-right
                {41, 77}, // bottom
                {5, 77},  // bottom-left
                {5, 41},  // left
                {5, 5}    // top-left
        };

        for (int slot = 0; slot < expected.length; slot++) {
            int expectedX = left + expected[slot][0];
            int expectedY = top + expected[slot][1];
            require(HotbarGridLayout.itemX(width, slot) == expectedX, "slot " + slot + " x");
            require(HotbarGridLayout.itemY(height, slot) == expectedY, "slot " + slot + " y");
            require(HotbarGridLayout.selectionX(width, slot) == expectedX - 5,
                    "slot " + slot + " selection x");
            require(HotbarGridLayout.selectionY(height, slot) == expectedY - 5,
                    "slot " + slot + " selection y");
        }

        int rightEdge = HotbarGridLayout.itemX(width, 4) + HotbarGridLayout.ITEM_SIZE;
        int bottomEdge = HotbarGridLayout.itemY(height, 4) + HotbarGridLayout.ITEM_SIZE;
        require(rightEdge == left + 93, "right item edge matches Visor image");
        require(bottomEdge == top + 93, "bottom item edge matches Visor image");

        expectInvalidSlot(-1);
        expectInvalidSlot(HotbarGridLayout.SLOT_COUNT);
    }

    private static void expectInvalidSlot(int slot) {
        try {
            HotbarGridLayout.itemX(400, slot);
            throw new AssertionError("expected invalid slot rejection: " + slot);
        } catch (IllegalArgumentException expected) {
            // Expected.
        }
    }

    private static void require(boolean condition, String message) {
        if (!condition) {
            throw new AssertionError(message);
        }
    }
}
