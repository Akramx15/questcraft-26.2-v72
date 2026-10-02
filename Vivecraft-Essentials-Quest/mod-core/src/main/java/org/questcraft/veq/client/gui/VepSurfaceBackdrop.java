package org.questcraft.veq.client.gui;

import net.minecraft.client.gui.GuiGraphicsExtractor;

/** Shared cohesive plate for normal and Creative wrist inventory surfaces. */
final class VepSurfaceBackdrop {
    static final int PADDING = 5;
    static final int SHADOW_OFFSET = 2;
    private static final int SHADOW = 0x70000000;
    private static final int COLOR = 0xE51B1E23;
    private static final int BORDER = 0xFF8B929C;

    private VepSurfaceBackdrop() {
    }

    static void render(
            GuiGraphicsExtractor graphics,
            VepWristInventoryScreen.Bounds content,
            int canvasWidth,
            int canvasHeight
    ) {
        VepWristInventoryScreen.Bounds plate = plateBounds(content, canvasWidth, canvasHeight);
        int left = plate.x();
        int top = plate.y();
        int right = left + plate.width();
        int bottom = top + plate.height();
        graphics.fill(
                left + SHADOW_OFFSET,
                top + SHADOW_OFFSET,
                Math.min(canvasWidth, right + SHADOW_OFFSET),
                Math.min(canvasHeight, bottom + SHADOW_OFFSET),
                SHADOW
        );
        graphics.fill(left, top, right, bottom, COLOR);
        graphics.outline(left, top, Math.max(1, plate.width()), Math.max(1, plate.height()), BORDER);
    }

    static VepWristInventoryScreen.Bounds visualBounds(
            VepWristInventoryScreen.Bounds content,
            int canvasWidth,
            int canvasHeight
    ) {
        VepWristInventoryScreen.Bounds plate = plateBounds(content, canvasWidth, canvasHeight);
        int right = Math.min(canvasWidth, plate.x() + plate.width() + SHADOW_OFFSET);
        int bottom = Math.min(canvasHeight, plate.y() + plate.height() + SHADOW_OFFSET);
        return new VepWristInventoryScreen.Bounds(
                plate.x(),
                plate.y(),
                Math.max(0, right - plate.x()),
                Math.max(0, bottom - plate.y())
        );
    }

    private static VepWristInventoryScreen.Bounds plateBounds(
            VepWristInventoryScreen.Bounds content,
            int canvasWidth,
            int canvasHeight
    ) {
        int left = Math.max(0, content.x() - PADDING);
        int top = Math.max(0, content.y() - PADDING);
        int right = Math.min(canvasWidth, content.x() + content.width() + PADDING);
        int bottom = Math.min(canvasHeight, content.y() + content.height() + PADDING);
        return new VepWristInventoryScreen.Bounds(
                left, top, Math.max(0, right - left), Math.max(0, bottom - top));
    }
}
