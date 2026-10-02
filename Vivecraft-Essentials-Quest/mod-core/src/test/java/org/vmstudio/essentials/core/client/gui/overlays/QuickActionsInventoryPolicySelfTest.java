package org.vmstudio.essentials.core.client.gui.overlays;

import org.vmstudio.visor.api.client.player.pose.PoseAnchor;
import org.vmstudio.visor.api.client.events.input.QuickActionsVREvent;
import org.vmstudio.visor.api.common.HandType;
import org.vmstudio.visor.api.common.eventbus.VREventHelper;
import org.vmstudio.visor.api.common.eventbus.event.VREventPriority;
import org.vmstudio.visor.api.common.eventbus.listener.VREventHandler;

import java.lang.reflect.Method;

public final class QuickActionsInventoryPolicySelfTest {
    private QuickActionsInventoryPolicySelfTest() {
    }

    public static void main(String[] args) throws ReflectiveOperationException {
        require(
                QuickActionsInventoryPolicy.selectPlan(
                        true, true, true, true, true, false
                ) == QuickActionsInventoryPolicy.TransactionPlan.PICKUP_THEN_PICKUP_ALL,
                "an empty cursor must PICKUP then PICKUP_ALL"
        );
        require(
                QuickActionsInventoryPolicy.selectPlan(
                        true, true, true, true, false, true
                ) == QuickActionsInventoryPolicy.TransactionPlan.PICKUP_ALL,
                "a matching carried stack must use PICKUP_ALL"
        );
        require(
                QuickActionsInventoryPolicy.selectPlan(
                        true, true, true, true, false, false
                ) == QuickActionsInventoryPolicy.TransactionPlan.NONE,
                "a mismatched carried stack must not be replaced"
        );
        requireNone(false, true, true, true, true, false,
                "release must pass through");
        requireNone(true, false, true, true, true, false,
                "hidden overlay must pass through");
        requireNone(true, true, false, true, true, false,
                "unfocused overlay must pass through");
        requireNone(true, true, true, false, true, false,
                "unsafe slot must pass through");
        require(QuickActionsInventoryPolicy.isExcludedSlotRole("PaymentSlot"),
                "payment slots must be excluded");
        require(QuickActionsInventoryPolicy.isExcludedSlotRole("GhostSlot"),
                "ghost slots must be excluded");
        require(QuickActionsInventoryPolicy.isExcludedSlotRole("FurnaceResultSlot"),
                "result slots must be excluded");
        require(!QuickActionsInventoryPolicy.isExcludedSlotRole("Slot"),
                "ordinary slots must remain eligible");
        require(VROverlayInventory.usedHandForAnchor(PoseAnchor.MAIN_HAND)
                        == HandType.MAIN,
                "main-hand wrist anchoring must retain main-hand interaction");
        require(VROverlayInventory.usedHandForAnchor(PoseAnchor.OFFHAND)
                        == HandType.OFFHAND,
                "offhand wrist anchoring must retain offhand interaction");
        require(VROverlayInventory.usedHandForAnchor(PoseAnchor.HMD) == null,
                "non-hand anchors must not claim a controller hand");
        verifyExpandedCursorCoordinates();

        require(VREventHelper.isCancelable(QuickActionsVREvent.class),
                "QuickActionsVREvent must be cancelable in the matching Visor build");
        assertPriority("onQuickActionsCollect", VREventPriority.LOWEST);
        assertPriority("onQuickActionsFallback", VREventPriority.HIGHEST);
    }

    private static void verifyExpandedCursorCoordinates() {
        float extraBounds = 0.6f;
        requireFloat(0.5f,
                VROverlayInventory.cursorCoordinateWithMargin(-0.3f, extraBounds),
                "the negative margin edge must remain accepted");
        requireFloat(0.5f,
                VROverlayInventory.cursorCoordinateWithMargin(0.49f, extraBounds),
                "the inner lower half must retain the established center mapping");
        requireFloat(0.5f,
                VROverlayInventory.cursorCoordinateWithMargin(0.5f, extraBounds),
                "the exact center must remain unchanged");
        requireFloat(0.5f,
                VROverlayInventory.cursorCoordinateWithMargin(1.3f, extraBounds),
                "the positive margin edge must remain accepted");
        requireFloat(-0.31f,
                VROverlayInventory.cursorCoordinateWithMargin(-0.31f, extraBounds),
                "coordinates outside the negative margin must pass through");
        requireFloat(1.31f,
                VROverlayInventory.cursorCoordinateWithMargin(1.31f, extraBounds),
                "coordinates outside the positive margin must pass through");

        float[] margins = {0.0f, 0.2f, 0.6f, 1.0f};
        for (float margin : margins) {
            for (int step = -200; step <= 200; step++) {
                float coordinate = step / 100.0f;
                requireFloat(
                        legacyCursorCoordinateWithMargin(coordinate, margin),
                        VROverlayInventory.cursorCoordinateWithMargin(coordinate, margin),
                        "allocation-free cursor math must match the previous formula"
                );
            }
        }
    }

    private static float legacyCursorCoordinateWithMargin(float coordinate,
                                                           float extraBounds) {
        float margin = extraBounds / 2;
        float result = 0.0f;
        if ((coordinate < 0.5 && coordinate >= -margin)
                || (coordinate > 0.5 && coordinate <= 1 + margin)) {
            result = 0.5f;
        } else {
            result = coordinate;
        }
        return result;
    }

    private static void requireFloat(float expected, float actual, String message) {
        require(Float.floatToIntBits(expected) == Float.floatToIntBits(actual),
                message + "; expected " + expected + " but got " + actual);
    }

    private static void requireNone(boolean pressEvent,
                                    boolean overlayVisible,
                                    boolean overlayFocused,
                                    boolean safeHoveredSlot,
                                    boolean carriedEmpty,
                                    boolean carriedMatchesHovered,
                                    String message) {
        require(
                QuickActionsInventoryPolicy.selectPlan(
                        pressEvent,
                        overlayVisible,
                        overlayFocused,
                        safeHoveredSlot,
                        carriedEmpty,
                        carriedMatchesHovered
                ) == QuickActionsInventoryPolicy.TransactionPlan.NONE,
                message
        );
    }

    private static void assertPriority(String methodName,
                                       VREventPriority expected)
            throws ReflectiveOperationException {
        Method method = VROverlayInventory.class.getMethod(
                methodName,
                QuickActionsVREvent.class
        );
        VREventHandler handler = method.getAnnotation(VREventHandler.class);
        require(handler != null, methodName + " must be an event handler");
        require(handler.priority() == expected,
                methodName + " must run at " + expected);
        require(!handler.ignoreCancelled(),
                methodName + " must not run after another handler cancels B");
    }

    private static void require(boolean condition, String message) {
        if (!condition) {
            throw new AssertionError(message);
        }
    }
}
