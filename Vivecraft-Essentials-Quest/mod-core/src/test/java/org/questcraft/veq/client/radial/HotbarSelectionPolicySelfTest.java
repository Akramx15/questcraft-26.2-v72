package org.questcraft.veq.client.radial;

import org.vivecraft.client_vr.provider.ControllerType;

public final class HotbarSelectionPolicySelfTest {
    private HotbarSelectionPolicySelfTest() {
    }

    public static void main(String[] args) {
        require(HotbarSelectionPolicy.operationFor(ControllerType.RIGHT) ==
                HotbarSelectionPolicy.Operation.SELECT_MAIN_HAND, "right selects main hotbar");
        require(HotbarSelectionPolicy.operationFor(ControllerType.LEFT) ==
                HotbarSelectionPolicy.Operation.SWAP_WITH_OFFHAND, "left swaps with offhand");
        require(HotbarSelectionPolicy.operationFor(null) ==
                HotbarSelectionPolicy.Operation.REJECT, "missing origin fails closed");
        require(!HotbarSelectionPolicy.canSwapToOffhand(4, 4),
                "active main slot cannot be moved to offhand");
        require(HotbarSelectionPolicy.canSwapToOffhand(3, 4),
                "different hotbar slot can swap once");
        for (ControllerType controller : ControllerType.values()) {
            ControllerType other = controller == ControllerType.LEFT
                    ? ControllerType.RIGHT : ControllerType.LEFT;
            require(!HotbarSelectionPolicy.canReleaseSelection(
                            controller, controller, false, -1),
                    controller + " no-sample release cannot select");
            require(!HotbarSelectionPolicy.canReleaseSelection(
                            controller, controller, false, 4),
                    controller + " pointed-to-unpointed release cannot select stale hover");
            require(!HotbarSelectionPolicy.canReleaseSelection(
                            controller, other, true, 4),
                    controller + " release cannot be stolen by the other hand");
            require(HotbarSelectionPolicy.canReleaseSelection(
                            controller, controller, true, 4),
                    controller + " current pointed hover can select");
        }
        for (int slot = 0; slot < HotbarGridLayout.SLOT_COUNT; slot++) {
            require(HotbarSelectionPolicy.menuSlot(slot) == 36 + slot, "menu slot " + slot);
        }
        require(HotbarSelectionPolicy.OFFHAND_SWAP_BUTTON == 40, "vanilla offhand swap button");
        expectInvalid(-1);
        expectInvalid(9);
    }

    private static void expectInvalid(int slot) {
        try {
            HotbarSelectionPolicy.menuSlot(slot);
            throw new AssertionError("expected invalid slot: " + slot);
        } catch (IllegalArgumentException expected) {
            // Expected.
        }
    }

    private static void require(boolean condition, String message) {
        if (!condition) {
            throw new AssertionError(message);
        }
    }
}
