package org.vivecraft.client_vr.gameplay.screenhandlers;

/**
 * Narrow policy for the Quest right-B GUI close action.
 *
 * <p>The caller is responsible for proving the exact screen/menu identities
 * before and after the neutral-button handoff. This helper deliberately
 * accepts only native world containers and Minecraft's two ordinary player
 * inventory screens. An externally claimed player inventory is rejected so a
 * Wrist-owned screen cannot be closed by B. Native world containers remain
 * eligible when their renderer/pointer is owned by a contextual overlay;
 * Minecraft still owns their screen/menu lifecycle.</p>
 */
public final class QuestBGuiClosePolicy {
    private QuestBGuiClosePolicy() {
    }

    public static boolean isEligible(
        boolean nativeWorldContainer,
        boolean playerInventory,
        boolean creativeInventory,
        boolean externalOverlayClaim,
        boolean playerOwnsScreenMenu,
        boolean playerUsesInventoryMenu
    ) {
        if (externalOverlayClaim && (playerInventory || creativeInventory)) {
            return false;
        }
        // CreativeModeInventoryScreen owns a transient ItemPickerMenu while
        // LocalPlayer#containerMenu deliberately remains inventoryMenu. The
        // close gate still pins the exact Creative screen/menu object pair;
        // only its player-ownership proof differs from ordinary containers.
        if (creativeInventory) {
            return playerUsesInventoryMenu;
        }
        return playerOwnsScreenMenu && (nativeWorldContainer || playerInventory);
    }
}
