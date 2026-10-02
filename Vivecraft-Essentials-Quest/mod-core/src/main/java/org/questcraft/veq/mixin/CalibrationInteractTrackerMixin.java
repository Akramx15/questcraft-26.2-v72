package org.questcraft.veq.mixin;

import net.minecraft.client.player.LocalPlayer;
import org.questcraft.veq.client.overlay.WristOverlayHandler;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.Inject;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfo;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfoReturnable;
import org.vivecraft.client_vr.gameplay.trackers.InteractTracker;

/** Prevents ImmersiveMC/interact modules from consuming either calibration hand. */
@Mixin(value = InteractTracker.class, priority = 2000)
public abstract class CalibrationInteractTrackerMixin {
    @Inject(method = "isActive", at = @At("HEAD"), cancellable = true)
    private void veq$disableInteractDuringCalibration(
            LocalPlayer player,
            CallbackInfoReturnable<Boolean> cir
    ) {
        if (WristOverlayHandler.isCalibrating()) {
            cir.setReturnValue(false);
        }
    }

    @Inject(method = "activeProcess", at = @At("HEAD"), cancellable = true)
    private void veq$stopInteractProcessingDuringCalibration(LocalPlayer player, CallbackInfo ci) {
        if (WristOverlayHandler.isCalibrating()) {
            ci.cancel();
        }
    }

    @Inject(method = "processBindings", at = @At("HEAD"), cancellable = true)
    private void veq$stopInteractBindingsDuringCalibration(CallbackInfo ci) {
        if (WristOverlayHandler.isCalibrating()) {
            ci.cancel();
        }
    }
}
