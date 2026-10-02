package org.vmstudio.essentials.core.mixin.client.compat.visor;

import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.Pseudo;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.Inject;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfoReturnable;
import org.vmstudio.essentials.core.client.gui.NativeContainerPlacement;

/** Lets the game action set win while a world container owns the native screen. */
@Pseudo
@Mixin(
        targets = "org.vmstudio.visor.core.client.input.actionset.MenuActionSet",
        remap = false
)
public abstract class MenuActionSetMixin {

    @Inject(method = "canActivate()Z", at = @At("HEAD"),
            cancellable = true, remap = false)
    private void visorEssentials$deactivateForWorldContainer(
            CallbackInfoReturnable<Boolean> cir) {
        if (NativeContainerPlacement.isActive()) {
            cir.setReturnValue(false);
        }
    }
}
