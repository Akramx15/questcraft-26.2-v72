package org.questcraft.veq.client.radial;

import org.vivecraft.client_vr.provider.ControllerType;

/** Maps a latched logical Grip controller to one server-authoritative action. */
public final class HotbarSelectionPolicy {
    public static final int HOTBAR_MENU_SLOT_BASE = 36;
    public static final int OFFHAND_SWAP_BUTTON = 40;

    private HotbarSelectionPolicy() {
    }

    public static Operation operationFor(ControllerType controller) {
        if (controller == null) {
            return Operation.REJECT;
        }
        return controller == ControllerType.LEFT ?
                Operation.SWAP_WITH_OFFHAND : Operation.SELECT_MAIN_HAND;
    }

    public static boolean canSwapToOffhand(int chosenSlot, int activeMainSlot) {
        return chosenSlot >= 0 && chosenSlot < HotbarGridLayout.SLOT_COUNT && chosenSlot != activeMainSlot;
    }

    /** Release must belong to the opener and still point at this session's valid hover. */
    public static boolean canReleaseSelection(ControllerType opener,
                                              ControllerType releaseController,
                                              boolean pointed,
                                              int hoveredSlot) {
        return opener != null && opener == releaseController && pointed
                && hoveredSlot >= 0 && hoveredSlot < HotbarGridLayout.SLOT_COUNT;
    }

    public static int menuSlot(int hotbarSlot) {
        if (hotbarSlot < 0 || hotbarSlot >= HotbarGridLayout.SLOT_COUNT) {
            throw new IllegalArgumentException("Hotbar slot must be in [0, 8]: " + hotbarSlot);
        }
        return HOTBAR_MENU_SLOT_BASE + hotbarSlot;
    }

    /** Pure SWAP semantics used both by runtime confirmation and invariant tests. */
    public static <T> SwapPair<T> swapped(T hotbarBefore, T offhandBefore) {
        return new SwapPair<>(offhandBefore, hotbarBefore);
    }

    public record SwapPair<T>(T hotbarAfter, T offhandAfter) {
    }

    public enum Operation {
        SELECT_MAIN_HAND,
        SWAP_WITH_OFFHAND,
        REJECT
    }
}
