package org.vmstudio.essentials.core.mixin.client.compat.visor;

import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.Pseudo;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.Inject;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfoReturnable;
import org.vmstudio.essentials.core.client.gui.NativeContainerPlacement;

/** Keeps VR locomotion available while a world-anchored native container is open. */
@Pseudo
@Mixin(
        targets = "org.vmstudio.visor.core.client.input.actionset.GameActionSet",
        remap = false
)
public abstract class GameActionSetMixin {

    @Inject(method = "canActivate()Z", at = @At("HEAD"),
            cancellable = true, remap = false)
    private void visorEssentials$activateForWorldContainer(
            CallbackInfoReturnable<Boolean> cir) {
        if (NativeContainerPlacement.isActive()) {
            cir.setReturnValue(true);
        }
    }
}
