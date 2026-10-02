package org.questcraft.veq.client.gui;

public final class VepSurfaceBackdropSelfTest {
    private VepSurfaceBackdropSelfTest() {
    }

    public static void main(String[] args) {
        VepWristInventoryScreen.Bounds content =
                new VepWristInventoryScreen.Bounds(20, 30, 100, 80);
        VepWristInventoryScreen.Bounds visual =
                VepSurfaceBackdrop.visualBounds(content, 320, 180);
        require(visual.x() == 15 && visual.y() == 25,
                "visual bounds must include plate padding");
        require(visual.width() == 112 && visual.height() == 92,
                "visual bounds must include positive shadow without changing hit bounds");

        VepWristInventoryScreen.Bounds clamped = VepSurfaceBackdrop.visualBounds(
                new VepWristInventoryScreen.Bounds(0, 0, 320, 180), 320, 180);
        require(clamped.x() == 0 && clamped.y() == 0 &&
                        clamped.width() == 320 && clamped.height() == 180,
                "full-canvas plates must clamp safely");
        System.out.println("VepSurfaceBackdropSelfTest PASS");
    }

    private static void require(boolean condition, String message) {
        if (!condition) {
            throw new AssertionError(message);
        }
    }
}
