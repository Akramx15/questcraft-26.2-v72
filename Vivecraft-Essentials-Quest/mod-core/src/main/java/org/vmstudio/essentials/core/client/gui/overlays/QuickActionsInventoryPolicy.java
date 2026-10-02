package org.vmstudio.essentials.core.client.gui.overlays;

/** Pure decision table for the contextual B action. */
final class QuickActionsInventoryPolicy {
    private QuickActionsInventoryPolicy() {
    }

    static TransactionPlan selectPlan(boolean pressEvent,
                                      boolean overlayVisible,
                                      boolean overlayFocused,
                                      boolean safeHoveredSlot,
                                      boolean carriedEmpty,
                                      boolean carriedMatchesHovered) {
        if (!pressEvent
                || !overlayVisible
                || !overlayFocused
                || !safeHoveredSlot) {
            return TransactionPlan.NONE;
        }
        if (carriedEmpty) {
            return TransactionPlan.PICKUP_THEN_PICKUP_ALL;
        }
        return carriedMatchesHovered
                ? TransactionPlan.PICKUP_ALL
                : TransactionPlan.NONE;
    }

    static boolean isExcludedSlotRole(String simpleClassName) {
        return simpleClassName.endsWith("ResultSlot")
                || simpleClassName.equals("PaymentSlot")
                || simpleClassName.contains("Ghost");
    }

    enum TransactionPlan {
        NONE,
        PICKUP_THEN_PICKUP_ALL,
        PICKUP_ALL;

        boolean handled() {
            return this != NONE;
        }
    }
}
