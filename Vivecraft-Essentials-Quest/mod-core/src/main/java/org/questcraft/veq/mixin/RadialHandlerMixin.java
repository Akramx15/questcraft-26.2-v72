package org.questcraft.veq.mixin;

import org.questcraft.veq.client.config.WristUiConfig;
import org.questcraft.veq.client.input.GripRuntimeGate;
import org.questcraft.veq.client.radial.RadialHotbarController;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.Inject;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfo;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfoReturnable;
import org.vivecraft.client_vr.gameplay.screenhandlers.RadialHandler;
import org.vivecraft.client_vr.provider.ControllerType;

@Mixin(RadialHandler.class)
public abstract class RadialHandlerMixin {
    @Inject(method = "processGui", at = @At("HEAD"), cancellable = true)
    private static void veq$closeWhenOwnershipChanges(CallbackInfo callback) {
        ControllerType activeController = RadialHandler.getActiveController();
        if (RadialHandler.isShowing() && !GripRuntimeGate.allowRadial(activeController)) {
            RadialHandler.cancelSession();
            callback.cancel();
        }
    }

    @Inject(method = "processBindings", at = @At("HEAD"), cancellable = true)
    private static void veq$cancelBeforeReleaseSelection(CallbackInfo callback) {
        ControllerType activeController = RadialHandler.getActiveController();
        if (RadialHandler.isShowing() && !GripRuntimeGate.allowRadial(activeController)) {
            // Never dispatch click/SWAP/haptic when a higher owner starts after
            // processGui but before release handling in the same frame.
            RadialHandler.cancelSession();
            callback.cancel();
        }
    }

    @Inject(method = "setOverlayShowing", at = @At("HEAD"), cancellable = true)
    private static void veq$prioritizeInteractions(
            boolean showing,
            ControllerType controller,
            CallbackInfoReturnable<Boolean> callback
    ) {
        if (!showing) {
            // Close both implementations. The original method continues so a
            // disabled/legacy Vivecraft radial is also cancelled safely.
            RadialHotbarController.cancel();
            return;
        }
        if (WristUiConfig.getInstance().radialHotbarEnabled()) {
            callback.setReturnValue(RadialHotbarController.open(controller));
            return;
        }
        if (showing && !GripRuntimeGate.allowRadial(controller)) {
            callback.setReturnValue(false);
        }
    }
}
