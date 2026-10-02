package org.vmstudio.essentials.core.mixin.client;

import com.llamalad7.mixinextras.injector.ModifyExpressionValue;
import net.minecraft.client.MouseHandler;
import net.minecraft.client.gui.screens.Screen;
import net.minecraft.client.input.MouseButtonInfo;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.Unique;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.Inject;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfo;
import org.vmstudio.essentials.core.client.gui.NativeContainerPlacement;
import org.vmstudio.visor.api.VisorAPI;

/**
 * Routes controller clicks outside an anchored container to Minecraft instead
 * of the native Screen. A ray on the panel keeps the normal Screen path, so
 * slots and injected IPN/JEI widgets remain fully clickable.
 */
@Mixin(MouseHandler.class)
public abstract class MouseHandlerMixin {
    @Unique
    private int visorEssentials$worldMouseButtons;
    @Unique
    private boolean visorEssentials$routeCurrentMouseEvent;

    @Inject(method = "onButton", at = @At("HEAD"))
    private void visorEssentials$selectMouseRoute(
            long window,
            MouseButtonInfo buttonInfo,
            int action,
            CallbackInfo ci) {
        int bit = 1 << buttonInfo.button();
        if (action == 1) {
            // A new press is the ownership boundary. It either replaces an
            // old world tombstone or clears it for an actual UI press.
            visorEssentials$worldMouseButtons &= ~bit;
            visorEssentials$routeCurrentMouseEvent =
                    NativeContainerPlacement.isActive()
                            && VisorAPI.client().getGuiManager()
                            .getCursorHandler().getFocusedOverlay() == null;
            if (visorEssentials$routeCurrentMouseEvent) {
                visorEssentials$worldMouseButtons |= bit;
            }
        } else {
            // Keep routing every release belonging to this press. Visor may
            // synthesize an early release when the ray enters the panel, then
            // emit the physical release later; both must miss the Screen.
            visorEssentials$routeCurrentMouseEvent =
                    (visorEssentials$worldMouseButtons & bit) != 0;
        }
    }

    @ModifyExpressionValue(
            method = "onButton",
            at = @At(
                    value = "INVOKE",
                    target = "Lnet/minecraft/client/gui/Gui;screen()Lnet/minecraft/client/gui/screens/Screen;"
            ),
            require = 4
    )
    private Screen visorEssentials$routeMouseOutsideContainer(Screen original) {
        return visorEssentials$routeCurrentMouseEvent ? null : original;
    }

    @Inject(method = "onButton", at = @At("RETURN"))
    private void visorEssentials$finishMouseRoute(
            long window,
            MouseButtonInfo buttonInfo,
            int action,
            CallbackInfo ci) {
        // World ownership deliberately survives releases as a tombstone and
        // is replaced only by the next press for this button.
        visorEssentials$routeCurrentMouseEvent = false;
    }
}
