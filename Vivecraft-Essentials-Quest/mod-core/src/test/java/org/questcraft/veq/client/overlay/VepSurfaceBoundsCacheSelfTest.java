package org.questcraft.veq.client.overlay;

import org.vivecraft.client_vr.gameplay.screenhandlers.ExternalScreenOverlayHandler;

public final class VepSurfaceBoundsCacheSelfTest {
    private VepSurfaceBoundsCacheSelfTest() {
    }

    public static void main(String[] args) {
        VepSurfaceBoundsCache<String> cache = new VepSurfaceBoundsCache<>();
        Object content = new Object();
        Object screen = new Object();

        require(!cache.matches(content, screen, 504, 270, 1L),
                "empty cache matched");
        cache.store(content, screen, 504, 270, 1L, "bounds-a");
        require(cache.matches(content, screen, 504, 270, 1L),
                "stored key did not match");
        require("bounds-a".equals(cache.value()), "stored value changed");

        require(!cache.matches(new Object(), screen, 504, 270, 1L),
                "content identity was ignored");
        require(!cache.matches(content, new Object(), 504, 270, 1L),
                "screen identity was ignored");
        require(!cache.matches(content, screen, 505, 270, 1L),
                "scaled width was ignored");
        require(!cache.matches(content, screen, 504, 271, 1L),
                "scaled height was ignored");
        require(!cache.matches(content, screen, 504, 270, 2L),
                "layout revision was ignored");

        cache.store(content, screen, 504, 270, 2L, "bounds-b");
        require("bounds-b".equals(cache.value()), "updated value was not published");
        cache.invalidate();
        require(!cache.matches(content, screen, 504, 270, 2L),
                "invalidated cache still matched");

        boolean rejectedNull = false;
        try {
            cache.store(content, screen, 504, 270, 3L, null);
        } catch (IllegalArgumentException expected) {
            rejectedNull = true;
        }
        require(rejectedNull, "cache accepted a null bounds value");

        carriedDropMustNotChangeVisualBounds();
    }

    private static void carriedDropMustNotChangeVisualBounds() {
        VepSurfaceBoundsCache<ExternalScreenOverlayHandler.SurfaceBounds> cache =
                new VepSurfaceBoundsCache<>();
        CarriedPointerOwnership<Object, Object, Object> ownership =
                new CarriedPointerOwnership<>();
        Object content = new Object();
        Object screen = new Object();
        Object menu = new Object();
        Object controller = new Object();
        ExternalScreenOverlayHandler.SurfaceBounds visualCrop =
                new ExternalScreenOverlayHandler.SurfaceBounds(118, 20, 270, 230);

        cache.store(content, screen, 504, 270, 7L, visualCrop);
        requireVisualCrop(cache.value(), visualCrop, "before pickup");

        require(ownership.retainOrCapture(screen, menu, controller, true),
                "carried controller could not capture ownership");
        require(ownership.owns(screen, menu, controller),
                "exact carried controller lost ownership");
        requireVisualCrop(cache.value(), visualCrop, "during carried stack");
        require(WristPointerPressPolicy.accepts(
                        false,
                        true,
                        ownership.owns(screen, menu, controller),
                        true,
                        12.0D,
                        12.0D,
                        504,
                        270,
                        false,
                        ExternalScreenOverlayHandler.PointerButton.PRIMARY),
                "outside drop was rejected while visual crop remained fixed");

        ownership.refresh(screen, menu, false);
        require(!ownership.isActive(), "carried ownership survived an empty cursor");
        requireVisualCrop(cache.value(), visualCrop, "after drop");
    }

    private static void requireVisualCrop(
            ExternalScreenOverlayHandler.SurfaceBounds actual,
            ExternalScreenOverlayHandler.SurfaceBounds expected,
            String phase
    ) {
        require(actual == expected, "visual crop object changed " + phase);
        require(!actual.isFull(), "visual crop expanded to the full canvas " + phase);
        require(actual.x() == 118 && actual.y() == 20
                        && actual.width() == 270 && actual.height() == 230,
                "visual crop geometry changed " + phase);
    }

    private static void require(boolean condition, String message) {
        if (!condition) {
            throw new AssertionError(message);
        }
    }
}
