package org.questcraft.veq.client.radial;

import org.vivecraft.client_vr.provider.ControllerType;

import java.util.Arrays;
import java.util.HashSet;
import java.util.Set;

/** Thirty alternating right-select/left-swap cycles must preserve every stack identity. */
public final class HotbarAlternatingSwapSelfTest {
    private HotbarAlternatingSwapSelfTest() {
    }

    public static void main(String[] args) {
        String[] hotbar = new String[HotbarGridLayout.SLOT_COUNT];
        for (int slot = 0; slot < hotbar.length; slot++) {
            hotbar[slot] = "hotbar-" + slot;
        }
        String offhand = "offhand";
        Set<String> expected = identities(hotbar, offhand);

        for (int step = 0; step < 30; step++) {
            int mainSlot = step % hotbar.length;
            int leftSlot = (mainSlot + 1 + step % (hotbar.length - 1)) % hotbar.length;
            require(HotbarSelectionPolicy.operationFor(ControllerType.RIGHT) ==
                    HotbarSelectionPolicy.Operation.SELECT_MAIN_HAND, "right operation");
            HotbarHandState.accepted(ControllerType.RIGHT, mainSlot);

            require(HotbarSelectionPolicy.canSwapToOffhand(leftSlot, mainSlot),
                    "left never aliases the active main slot");
            HotbarSelectionPolicy.SwapPair<String> swap =
                    HotbarSelectionPolicy.swapped(hotbar[leftSlot], offhand);
            hotbar[leftSlot] = swap.hotbarAfter();
            offhand = swap.offhandAfter();
            HotbarHandState.accepted(ControllerType.LEFT, leftSlot);

            require(identities(hotbar, offhand).equals(expected),
                    "cycle " + step + " cannot duplicate or lose an item");
            require(HotbarHandState.lastChoice(ControllerType.RIGHT) == mainSlot,
                    "cycle " + step + " right state");
            require(HotbarHandState.lastChoice(ControllerType.LEFT) == leftSlot,
                    "cycle " + step + " left state");
        }
    }

    private static Set<String> identities(String[] hotbar, String offhand) {
        Set<String> identities = new HashSet<>(Arrays.asList(hotbar));
        identities.add(offhand);
        require(identities.size() == HotbarGridLayout.SLOT_COUNT + 1,
                "all ten stack identities remain unique");
        return identities;
    }

    private static void require(boolean condition, String message) {
        if (!condition) {
            throw new AssertionError(message);
        }
    }
}
