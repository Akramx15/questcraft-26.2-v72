package org.vmstudio.essentials.core.mixin.client;

import net.minecraft.client.Minecraft;
import net.minecraft.client.gui.Gui;
import net.minecraft.client.gui.screens.Screen;
import net.minecraft.client.gui.screens.inventory.AbstractContainerScreen;
import net.minecraft.client.gui.screens.inventory.CreativeModeInventoryScreen;
import net.minecraft.client.gui.screens.inventory.InventoryScreen;
import org.spongepowered.asm.mixin.Final;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.Shadow;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.Inject;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfo;
import org.vmstudio.essentials.core.client.gui.NativeContainerPlacement;
import org.vmstudio.essentials.core.common.VisorEssentials;
import org.vmstudio.visor.api.VisorAPI;

/**
 * Observes native container screen changes and records their world anchor.
 * The call is never cancelled: the screen must remain Minecraft's real screen
 * so Fabric screen events and third-party widgets keep their normal lifecycle.
 */
@Mixin(Gui.class)
public abstract class GuiScreenMixin {

    @Shadow @Final
    private Minecraft minecraft;

    @Inject(method = "setScreen", at = @At("HEAD"))
    private void visorEssentials$trackNativeContainer(Screen newScreen, CallbackInfo ci) {
        Screen previousScreen = minecraft.gui.screen();
        boolean replacingPlacedContainer = NativeContainerPlacement.isActiveFor(previousScreen);

        if (newScreen == null) {
            if (replacingPlacedContainer) {
                NativeContainerPlacement.clear();
            }
            return;
        }

        boolean nativeContainer = newScreen instanceof AbstractContainerScreen<?>
                && !(newScreen instanceof InventoryScreen)
                && !(newScreen instanceof CreativeModeInventoryScreen);

        if (replacingPlacedContainer) {
            if (nativeContainer
                    && VisorEssentials.customInventory
                    && VisorAPI.clientState().stateMode().isActive()) {
                NativeContainerPlacement.retarget(newScreen);
            } else {
                NativeContainerPlacement.clear();
            }
            return;
        }

        // Only an interaction that opens a screen from gameplay establishes a
        // new world anchor. Menus opened by another screen remain head-facing.
        if (previousScreen != null
                || !nativeContainer
                || !VisorEssentials.customInventory
                || VisorAPI.clientState().stateMode().isNotActive()) {
            return;
        }

        NativeContainerPlacement.attach(newScreen, minecraft.hitResult);
    }
}
