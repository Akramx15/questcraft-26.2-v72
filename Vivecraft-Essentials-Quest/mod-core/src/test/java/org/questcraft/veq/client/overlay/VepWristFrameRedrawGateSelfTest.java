package org.questcraft.veq.client.overlay;

public final class VepWristFrameRedrawGateSelfTest {
    private VepWristFrameRedrawGateSelfTest() {
    }

    public static void main(String[] args) {
        Object screen = new Object();
        VepWristFrameRedrawGate gate = new VepWristFrameRedrawGate();

        require(gate.shouldRedraw(1_000L, screen, -1, false),
                "first content frame was skipped");
        // Model a failed Screen extraction: without markRendered the exact
        // same state must remain dirty and retry immediately.
        require(gate.shouldRedraw(2_000L, screen, -1, false),
                "failed content extraction was incorrectly committed");

        gate.markRendered(2_000L, screen, -1);
        require(!gate.shouldRedraw(3_000L, screen, -1, false),
                "unchanged content redrew after a successful commit");
        require(!gate.shouldRedraw(
                        2_000L + VepWristFrameRedrawGate.IDLE_REFRESH_NANOS - 1L,
                        screen, -1, false),
                "idle content refreshed before its deadline");
        require(gate.shouldRedraw(
                        2_000L + VepWristFrameRedrawGate.IDLE_REFRESH_NANOS,
                        screen, -1, false),
                "idle safety refresh did not run at its deadline");

        gate.markRendered(60_000_000L, screen, 4);
        require(!gate.shouldRedraw(60_001_000L, screen, 4, false),
                "motion inside one hover target rebuilt the base GUI");
        require(gate.shouldRedraw(60_002_000L, screen, 5, false),
                "hover target transition did not rebuild the base GUI");
        gate.markRendered(60_002_000L, screen, 5);
        require(gate.shouldRedraw(60_003_000L, screen, -1, false),
                "hover exit did not clean the base hover visual");

        gate.markRendered(60_004_000L, screen, -1);
        require(gate.shouldRedraw(60_004_100L, screen, -1, true),
                "animated player preview was throttled");
        gate.markRendered(60_004_100L, screen, -1);
        require(gate.shouldRedraw(60_004_200L, screen, -1, true),
                "animated preview did not stay full-rate");

        require(gate.shouldRedraw(60_005_000L, new Object(), -1, false),
                "screen identity change did not redraw");
        gate.markRendered(60_006_000L, screen, -1);
        gate.invalidate();
        require(gate.shouldRedraw(60_007_000L, screen, -1, false),
                "explicit invalidation did not redraw");

        gate.markRendered(60_008_000L, screen, -1);
        require(gate.shouldRedraw(1L, screen, -1, false),
                "monotonic clock regression did not redraw");

        VepScreenContent unknownContent = new VepScreenContent() {
            @Override
            public net.minecraft.client.gui.screens.Screen screen() {
                return null;
            }

            @Override
            public org.questcraft.veq.client.gui.VepWristInventoryScreen.Bounds contentBounds() {
                return null;
            }

            @Override
            public boolean containsInteractionPoint(double x, double y) {
                return true;
            }
        };
        int unknownHover = unknownContent.hoverKey(12.1D, 8.9D);
        require(unknownHover == -1,
                "unknown hosted content must use a stable semantic hover key");
        gate.markRendered(70_000_000L, unknownContent, unknownHover);
        require(!gate.shouldRedraw(70_001_000L, unknownContent,
                        unknownContent.hoverKey(401.7D, 219.2D), false),
                "pointer movement inside unknown content forced a full base redraw");

        int fallback = VepPointerHoverKey.logicalPixel(12.1D, 8.9D);
        require(fallback == VepPointerHoverKey.logicalPixel(12.9D, 8.1D),
                "subpixel jitter changed the conservative hover key");
        require(fallback != VepPointerHoverKey.logicalPixel(13.0D, 8.1D),
                "logical-pixel hover movement was hidden");
        require(VepPointerHoverKey.logicalPixel(Double.NaN, 8.0D) == -1,
                "non-finite hover coordinates must fail closed");
    }

    private static void require(boolean condition, String message) {
        if (!condition) {
            throw new AssertionError(message);
        }
    }
}
