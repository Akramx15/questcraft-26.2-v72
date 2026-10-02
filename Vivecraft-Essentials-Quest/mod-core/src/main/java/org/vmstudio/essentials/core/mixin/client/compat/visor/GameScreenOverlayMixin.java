package org.vmstudio.essentials.core.mixin.client.compat.visor;

import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.Pseudo;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.Inject;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfo;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfoReturnable;
import org.vmstudio.essentials.core.client.gui.NativeContainerPlacement;
import org.vmstudio.visor.api.client.gui.overlays.VROverlay;

/** Reposes Visor's single native game-screen panel for a world container. */
@Pseudo
@Mixin(
        targets = "org.vmstudio.visor.core.client.gui.overlays.builtin.VROverlayGameScreen",
        remap = false
)
public abstract class GameScreenOverlayMixin {

    @Inject(method = "onUpdatePose(F)V", at = @At("TAIL"), remap = false)
    private void visorEssentials$placeNativeContainer(float partialTicks,
                                                       CallbackInfo ci) {
        NativeContainerPlacement.applyTo((VROverlay) (Object) this, partialTicks);
    }

    @Inject(method = "supportsDragging()Z", at = @At("HEAD"),
            cancellable = true, remap = false)
    private void visorEssentials$lockContainerAnchor(
            CallbackInfoReturnable<Boolean> cir) {
        if (NativeContainerPlacement.isActive()) {
            cir.setReturnValue(false);
        }
    }

    @Inject(method = "supportsResizing()Z", at = @At("HEAD"),
            cancellable = true, remap = false)
    private void visorEssentials$lockContainerScale(
            CallbackInfoReturnable<Boolean> cir) {
        if (NativeContainerPlacement.isActive()) {
            cir.setReturnValue(false);
        }
    }
}
