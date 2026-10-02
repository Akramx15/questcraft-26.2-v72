package org.vmstudio.essentials.core.client.gui.screens;

import org.vmstudio.essentials.core.client.config.WristHudPosition;

import java.util.List;

public final class VRInvScreenLayoutCacheSelfTest {
    private static final int LEFT = 100;
    private static final int TOP = 50;
    private static final int SCREEN_WIDTH = 640;
    private static final int SCREEN_HEIGHT = 360;
    private static final int IMAGE_WIDTH = 258;
    private static final int IMAGE_HEIGHT = 156;

    private VRInvScreenLayoutCacheSelfTest() {
    }

    public static void main(String[] args) {
        verifyStatusLayoutInvalidation();
        verifyCombinedBoundsInvalidation();
        verifyCombinedBoundsAndHitRegions();
        verifyVisibleUtilityActionReuse();
    }

    private static void verifyStatusLayoutInvalidation() {
        VRInvScreen.LayoutCacheState cache = new VRInvScreen.LayoutCacheState();
        require(cache.shouldRebuildStatusLayout(LEFT, TOP, IMAGE_HEIGHT, 4L),
                "the first status layout lookup must build");
        require(!cache.shouldRebuildStatusLayout(LEFT, TOP, IMAGE_HEIGHT, 4L),
                "unchanged status geometry must stay cached");
        require(cache.shouldRebuildStatusLayout(LEFT + 1, TOP, IMAGE_HEIGHT, 4L),
                "a horizontal position change must invalidate status geometry");
        require(cache.shouldRebuildStatusLayout(LEFT + 1, TOP + 1, IMAGE_HEIGHT, 4L),
                "a vertical position change must invalidate status geometry");
        require(cache.shouldRebuildStatusLayout(LEFT + 1, TOP + 1,
                        IMAGE_HEIGHT + 1, 4L),
                "an image resize must invalidate status geometry");
        require(cache.shouldRebuildStatusLayout(LEFT + 1, TOP + 1,
                        IMAGE_HEIGHT + 1, 5L),
                "a wrist config revision must invalidate status geometry");
        require(!cache.shouldRebuildStatusLayout(LEFT + 1, TOP + 1,
                        IMAGE_HEIGHT + 1, 5L),
                "the rebuilt status layout must be reused");
    }

    private static void verifyCombinedBoundsInvalidation() {
        VRInvScreen.LayoutCacheState cache = new VRInvScreen.LayoutCacheState();
        cache.shouldRebuildStatusLayout(LEFT, TOP, IMAGE_HEIGHT, 9L);

        require(rebuildCombined(cache, LEFT, TOP, SCREEN_WIDTH, SCREEN_HEIGHT,
                        true, 0, false, false, 6, 2),
                "the first combined-bounds lookup must build");
        require(!rebuildCombined(cache, LEFT, TOP, SCREEN_WIDTH, SCREEN_HEIGHT,
                        true, 0, false, false, 6, 2),
                "unchanged combined bounds must stay cached");
        require(rebuildCombined(cache, LEFT + 1, TOP, SCREEN_WIDTH, SCREEN_HEIGHT,
                        true, 0, false, false, 6, 2),
                "screen position must invalidate combined bounds");
        require(rebuildCombined(cache, LEFT + 1, TOP, SCREEN_WIDTH + 1, SCREEN_HEIGHT,
                        true, 0, false, false, 6, 2),
                "screen resize must invalidate effect-aware bounds");
        require(rebuildCombined(cache, LEFT + 1, TOP, SCREEN_WIDTH + 1, SCREEN_HEIGHT,
                        true, 1, false, false, 6, 2),
                "a visible effect row change must invalidate combined bounds");
        require(rebuildCombined(cache, LEFT + 1, TOP, SCREEN_WIDTH + 1, SCREEN_HEIGHT,
                        true, 1, true, false, 6, 2),
                "context-action visibility must invalidate combined bounds");
        require(rebuildCombined(cache, LEFT + 1, TOP, SCREEN_WIDTH + 1, SCREEN_HEIGHT,
                        true, 1, true, true, 6, 2),
                "creative-action visibility must invalidate combined bounds");
        require(rebuildCombined(cache, LEFT + 1, TOP, SCREEN_WIDTH + 1, SCREEN_HEIGHT,
                        true, 1, true, true, 12, 2),
                "quick-action config changes must invalidate combined bounds");
        require(rebuildCombined(cache, LEFT + 1, TOP, SCREEN_WIDTH + 1, SCREEN_HEIGHT,
                        true, 1, true, true, 12, 3),
                "utility-action visibility must invalidate combined bounds");
        require(rebuildCombined(cache, LEFT + 1, TOP, SCREEN_WIDTH + 1, SCREEN_HEIGHT,
                        false, 1, true, false, 0, 0),
                "full/simplified inventory changes must invalidate combined bounds");
        require(cache.shouldRebuildStatusLayout(LEFT + 1, TOP, IMAGE_HEIGHT, 10L),
                "a new config revision must rebuild status geometry");
        require(rebuildCombined(cache, LEFT + 1, TOP, SCREEN_WIDTH + 1, SCREEN_HEIGHT,
                        false, 1, true, false, 0, 0),
                "a status rebuild must invalidate dependent combined bounds");
        require(!rebuildCombined(cache, LEFT + 1, TOP, SCREEN_WIDTH + 1, SCREEN_HEIGHT,
                        false, 1, true, false, 0, 0),
                "rebuilt combined bounds must be reused");
        cache.invalidateCombinedBounds();
        require(rebuildCombined(cache, LEFT + 1, TOP, SCREEN_WIDTH + 1, SCREEN_HEIGHT,
                        false, 1, true, false, 0, 0),
                "an action replacement must support explicit invalidation");
    }

    private static boolean rebuildCombined(VRInvScreen.LayoutCacheState cache,
                                           int left,
                                           int top,
                                           int screenWidth,
                                           int screenHeight,
                                           boolean fullInventory,
                                           int effects,
                                           boolean contextAction,
                                           boolean creativeAction,
                                           int quickActions,
                                           int utilityActions) {
        return cache.shouldRebuildCombinedBounds(
                left,
                top,
                screenWidth,
                screenHeight,
                IMAGE_WIDTH,
                IMAGE_HEIGHT,
                fullInventory,
                effects,
                contextAction,
                creativeAction,
                quickActions,
                utilityActions
        );
    }

    private static void verifyCombinedBoundsAndHitRegions() {
        VRInvScreen.StatusGroup topGroup = new VRInvScreen.StatusGroup(
                WristHudPosition.TOP,
                new VRInvScreen.InventoryBounds(142, 34, 174, 17),
                2,
                1,
                List.of()
        );
        VRInvScreen.StatusGroup bottomGroup = new VRInvScreen.StatusGroup(
                WristHudPosition.BOTTOM,
                new VRInvScreen.InventoryBounds(142, 205, 174, 17),
                2,
                1,
                List.of()
        );
        VRInvScreen.StatusLayout bothPositions = new VRInvScreen.StatusLayout(
                List.of(topGroup, bottomGroup),
                List.of()
        );

        requireBounds(
                VRInvScreen.calculateCombinedBounds(
                        LEFT, TOP, IMAGE_WIDTH, IMAGE_HEIGHT, true, null,
                        VRInvScreen.StatusLayout.EMPTY,
                        false, false, 0, 0
                ),
                100, 50, 258, 156,
                "the full inventory base region must remain unchanged"
        );
        requireBounds(
                VRInvScreen.calculateCombinedBounds(
                        LEFT, TOP, IMAGE_WIDTH, IMAGE_HEIGHT, true, null,
                        bothPositions,
                        true, true, 0, 0
                ),
                100, 8, 258, 240,
                "top HUD, bottom HUD, creative, and context regions must be included"
        );
        requireBounds(
                VRInvScreen.calculateCombinedBounds(
                        LEFT, TOP, IMAGE_WIDTH, IMAGE_HEIGHT, false, null,
                        bothPositions,
                        true, false, 12, 9
                ),
                140, 50, 178, 182,
                "simplified mode must ignore full-inventory HUD and shortcut regions"
        );
        requireBounds(
                VRInvScreen.calculateCombinedBounds(
                        LEFT, TOP, IMAGE_WIDTH, IMAGE_HEIGHT, true, null,
                        VRInvScreen.StatusLayout.EMPTY,
                        false, false, 12, 0
                ),
                98, 50, 262, 156,
                "all twelve quick actions must extend the focus region symmetrically"
        );
        requireBounds(
                VRInvScreen.calculateCombinedBounds(
                        LEFT, TOP, IMAGE_WIDTH, IMAGE_HEIGHT, true,
                        new VRInvScreen.InventoryBounds(360, 50, 120, 98),
                        VRInvScreen.StatusLayout.EMPTY,
                        false, false, 0, 0
                ),
                100, 50, 380, 156,
                "effect bounds must extend the cached focus region"
        );
        requireBounds(
                VRInvScreen.calculateCombinedBounds(
                        LEFT, TOP, IMAGE_WIDTH, IMAGE_HEIGHT, true, null,
                        VRInvScreen.StatusLayout.EMPTY,
                        false, false, 0, 9
                ),
                100, 50, 258, 200,
                "visible utility actions beyond the panel must remain interactive"
        );

        VRInvScreen.InventoryBounds context = VRInvScreen.contextActionBounds(
                LEFT, TOP, IMAGE_WIDTH, IMAGE_HEIGHT, true, bothPositions
        );
        requireBounds(context, 165, 228, 128, 20,
                "the context action must follow the bottom HUD group");
        assertHalfOpenHitRegion(context, "context action");

        VRInvScreen.InventoryBounds simplifiedContext =
                VRInvScreen.contextActionBounds(
                        LEFT, TOP, IMAGE_WIDTH, IMAGE_HEIGHT, false, bothPositions
                );
        requireBounds(simplifiedContext, 165, 212, 128, 20,
                "simplified context actions must stay under the base panel");

        VRInvScreen.InventoryBounds creative = VRInvScreen.creativeModeActionBounds(
                LEFT, TOP, IMAGE_WIDTH, bothPositions
        );
        requireBounds(creative, 165, 8, 128, 20,
                "the creative action must follow the top HUD group");
        assertHalfOpenHitRegion(creative, "creative action");

        VRInvScreen.InventoryBounds utility = VRInvScreen.utilityActionBounds(
                LEFT, TOP, 1
        );
        requireBounds(utility, 158, 76, 20, 20,
                "utility-action drawing and clicking must share coordinates");
        assertHalfOpenHitRegion(utility, "utility action");

        VRInvScreen.InventoryBounds quick = VRInvScreen.quickActionBounds(
                LEFT, TOP, 11
        );
        requireBounds(quick, 340, 184, 20, 20,
                "outer quick-action drawing and clicking must share coordinates");
        assertHalfOpenHitRegion(quick, "quick action");
    }

    private static void verifyVisibleUtilityActionReuse() {
        VRInvScreen.VisibleActionCache<TestAction> cache =
                new VRInvScreen.VisibleActionCache<>();
        TestAction first = new TestAction(true);
        TestAction second = new TestAction(false);
        TestAction third = new TestAction(true);
        List<TestAction> actions = List.of(first, second, third);

        List<TestAction> visible = cache.refresh(true, actions, action -> action.visible);
        require(visible.equals(List.of(first, third)),
                "visible utility actions must retain registration order");
        List<TestAction> reused = cache.refresh(true, actions, action -> action.visible);
        require(reused == visible,
                "unchanged visibility must reuse the same utility-action list");

        second.visible = true;
        List<TestAction> expanded = cache.refresh(true, actions, action -> action.visible);
        require(expanded == visible,
                "visibility changes must update rather than replace the cached list");
        require(expanded.equals(actions),
                "a newly visible utility action must be inserted in registration order");

        List<TestAction> hidden = cache.refresh(false, actions, action -> action.visible);
        require(hidden == visible && hidden.isEmpty(),
                "simplified mode must clear and reuse the utility-action list");
    }

    private static void assertHalfOpenHitRegion(VRInvScreen.InventoryBounds bounds,
                                                String name) {
        require(VRInvScreen.contains(bounds, bounds.x(), bounds.y()),
                name + " must include its top-left pixel");
        require(VRInvScreen.contains(
                        bounds,
                        bounds.x() + bounds.width() - 0.01D,
                        bounds.y() + bounds.height() - 0.01D
                ),
                name + " must include the interior of its bottom-right pixel");
        require(!VRInvScreen.contains(
                        bounds,
                        bounds.x() + bounds.width(),
                        bounds.y()
                ),
                name + " must exclude its right edge");
        require(!VRInvScreen.contains(
                        bounds,
                        bounds.x(),
                        bounds.y() + bounds.height()
                ),
                name + " must exclude its bottom edge");
    }

    private static void requireBounds(VRInvScreen.InventoryBounds actual,
                                      int x,
                                      int y,
                                      int width,
                                      int height,
                                      String message) {
        require(actual.equals(new VRInvScreen.InventoryBounds(x, y, width, height)),
                message + "; got " + actual);
    }

    private static void require(boolean condition, String message) {
        if (!condition) {
            throw new AssertionError(message);
        }
    }

    private static final class TestAction {
        private boolean visible;

        private TestAction(boolean visible) {
            this.visible = visible;
        }
    }
}
