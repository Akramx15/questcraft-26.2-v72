package org.questcraft.veq.client.overlay;

/** Fixed VEP logical canvas with a 2x render target. */
public final class VepSurfaceSizing {
    // 504 px leaves the full 258 px inventory plus VEP's 120 px named potion
    // strip without overlap. The cropped inventory itself remains compact.
    public static final int LOGICAL_WIDTH = 504;
    public static final int LOGICAL_HEIGHT = 270;
    public static final int RENDER_WIDTH = LOGICAL_WIDTH * 2;
    public static final int RENDER_HEIGHT = 540;

    private VepSurfaceSizing() {
    }

    public static float physicalContentWidth(int logicalPixels, float surfaceScale) {
        if (logicalPixels < 0 || !Float.isFinite(surfaceScale) || surfaceScale < 0.0F) {
            throw new IllegalArgumentException("Invalid VEP surface measurement");
        }
        return 1.5F * surfaceScale * logicalPixels / LOGICAL_WIDTH;
    }
}
