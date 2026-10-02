package org.vivecraft.client_vr.gameplay.screenhandlers;

import net.minecraft.client.Minecraft;
import net.minecraft.client.gui.screens.Screen;
import net.minecraft.client.gui.screens.inventory.AbstractContainerScreen;
import net.minecraft.client.gui.screens.inventory.CreativeModeInventoryScreen;
import net.minecraft.client.gui.screens.inventory.InventoryScreen;
import org.vivecraft.client_vr.VRState;

/**
 * Narrow opt-in for walking while a native container screen is open. The
 * screen keeps Vivecraft's ordinary player-relative GUI pose; locomotion is
 * intentionally independent of any overlay or placement owner.
 *
 * <p>Only a dedicated left-stick action inside the GUI action set drives
 * movement. The in-game and contextual action sets remain inactive, so world
 * actions stay owned by the GUI until it closes.</p>
 */
public final class NativeContainerLocomotion {
    private NativeContainerLocomotion() {
    }

    public static boolean isActive(Minecraft minecraft) {
        if (minecraft == null || minecraft.gui == null) {
            return false;
        }
        Screen screen = minecraft.gui.screen();
        var player = minecraft.player;
        boolean activeSession = player != null &&
            screen instanceof AbstractContainerScreen<?> container &&
            !(screen instanceof InventoryScreen) &&
            !(screen instanceof CreativeModeInventoryScreen) &&
            player.containerMenu == container.getMenu() &&
            player.inventoryMenu != container.getMenu();
        return shouldAllow(
            VRState.VR_RUNNING,
            minecraft.level != null,
            player != null,
            player != null && player.isAlive(),
            screen instanceof InventoryScreen,
            screen instanceof CreativeModeInventoryScreen,
            activeSession,
            false
        );
    }

    static boolean shouldAllow(
        boolean vrRunning,
        boolean worldPresent,
        boolean playerPresent,
        boolean playerAlive,
        boolean playerInventory,
        boolean creativeInventory,
        boolean playerOwnsMenu,
        boolean inventoryMenu
    ) {
        return vrRunning
            && worldPresent
            && playerPresent
            && playerAlive
            && !playerInventory
            && !creativeInventory
            && playerOwnsMenu
            && !inventoryMenu;
    }
}
