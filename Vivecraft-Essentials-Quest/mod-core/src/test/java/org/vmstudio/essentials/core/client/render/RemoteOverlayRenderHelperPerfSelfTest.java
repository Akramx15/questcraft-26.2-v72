package org.vmstudio.essentials.core.client.render;

import java.util.ArrayList;
import java.util.List;

/** Regression coverage for allocation-free empty frames and render ordering. */
public final class RemoteOverlayRenderHelperPerfSelfTest {
    private RemoteOverlayRenderHelperPerfSelfTest() {
    }

    public static void main(String[] args) {
        verifyLazyListReuse();
        verifyFarthestFirstOrdering();
    }

    private static void verifyLazyListReuse() {
        List<String> overlays = null;
        overlays = RemoteOverlayRenderHelper.appendOverlay(overlays, "far");
        require(overlays.equals(List.of("far")),
                "the first visible overlay must create and populate the list");

        List<String> allocated = overlays;
        overlays = RemoteOverlayRenderHelper.appendOverlay(overlays, "near");
        require(overlays == allocated,
                "subsequent visible overlays must reuse the same scratch list");
        require(overlays.equals(List.of("far", "near")),
                "lazy collection must retain discovery order before sorting");
    }

    private static void verifyFarthestFirstOrdering() {
        List<Double> distances = new ArrayList<>(List.of(4.0D, 25.0D, 1.0D, 9.0D));
        distances.sort(RemoteOverlayRenderHelper::compareDistanceFarthestFirst);
        require(distances.equals(List.of(25.0D, 9.0D, 4.0D, 1.0D)),
                "remote overlays must retain far-to-near rendering order");

        require(RemoteOverlayRenderHelper.compareDistanceFarthestFirst(7.0D, 7.0D) == 0,
                "equal distances must remain comparator-equal");
    }

    private static void require(boolean condition, String message) {
        if (!condition) {
            throw new AssertionError(message);
        }
    }
}
