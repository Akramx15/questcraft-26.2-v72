package org.questcraft.veq.mixin;

import net.minecraft.client.gui.Gui;
import net.minecraft.client.gui.screens.Screen;
import org.questcraft.veq.client.gui.WristSettingsScreen;
import org.questcraft.veq.client.overlay.WristOverlayHandler;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.Inject;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfo;

/** Hard-closes the embedded menu before a normal Minecraft screen takes over. */
@Mixin(value = Gui.class, priority = 2000)
public abstract class WristGuiTransitionMixin {
    @Inject(method = "setScreen", at = @At("HEAD"))
    private void veq$reconcileWristBeforeScreenChange(Screen nextScreen, CallbackInfo ci) {
        if (!(nextScreen instanceof WristSettingsScreen) || !WristOverlayHandler.isCalibrating()) {
            WristOverlayHandler.forceHide();
        }
    }
}
