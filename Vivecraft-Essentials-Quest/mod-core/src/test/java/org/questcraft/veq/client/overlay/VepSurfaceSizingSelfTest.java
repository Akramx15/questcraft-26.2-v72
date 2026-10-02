package org.questcraft.veq.client.overlay;

/** Regression coverage for the Visor-equivalent compact wrist canvas. */
public final class VepSurfaceSizingSelfTest {
    private VepSurfaceSizingSelfTest() {
    }

    public static void main(String[] args) {
        require(VepSurfaceSizing.LOGICAL_WIDTH == 504, "logical width");
        require(VepSurfaceSizing.LOGICAL_HEIGHT == 270, "logical height");
        require(VepSurfaceSizing.RENDER_WIDTH == VepSurfaceSizing.LOGICAL_WIDTH * 2,
                "2x render width");
        require(VepSurfaceSizing.RENDER_HEIGHT == VepSurfaceSizing.LOGICAL_HEIGHT * 2,
                "2x render height");
        float panelWidth = VepSurfaceSizing.physicalContentWidth(258, 0.5F);
        require(panelWidth > 0.38F && panelWidth < 0.39F,
                "258px VEP panel must remain compact at default scale, got " + panelWidth);
        System.out.println("VepSurfaceSizingSelfTest PASS");
    }

    private static void require(boolean condition, String message) {
        if (!condition) {
            throw new AssertionError(message);
        }
    }
}
