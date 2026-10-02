package org.questcraft.veq.mixin;

import net.minecraft.client.player.LocalPlayer;
import org.questcraft.veq.client.overlay.WristOverlayHandler;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.Inject;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfo;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfoReturnable;
import org.vivecraft.client_vr.gameplay.trackers.ClimbTracker;

/** Gives two-hand wrist calibration priority over every climb Grip path. */
@Mixin(value = ClimbTracker.class, priority = 2000)
public abstract class CalibrationClimbTrackerMixin {
    @Inject(method = "isActive", at = @At("HEAD"), cancellable = true)
    private void veq$disableClimbDuringCalibration(
            LocalPlayer player,
            CallbackInfoReturnable<Boolean> cir
    ) {
        if (WristOverlayHandler.isCalibrating()) {
            cir.setReturnValue(false);
        }
    }

    @Inject(method = "activeProcess", at = @At("HEAD"), cancellable = true)
    private void veq$stopClimbProcessingDuringCalibration(LocalPlayer player, CallbackInfo ci) {
        if (WristOverlayHandler.isCalibrating()) {
            ci.cancel();
        }
    }
}
