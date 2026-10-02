package org.vmstudio.essentials.core.mixin.client.compat.visor;

import com.llamalad7.mixinextras.injector.ModifyExpressionValue;
import net.minecraft.client.gui.screens.Screen;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.Pseudo;
import org.spongepowered.asm.mixin.injection.At;
import org.vmstudio.essentials.core.client.gui.NativeContainerPlacement;

/** Lets a trigger aimed away from the panel continue to the game world. */
@Pseudo
@Mixin(
        targets = "org.vmstudio.visor.core.client.input.mouse.MouseClickHandler",
        remap = false
)
public abstract class MouseClickHandlerMixin {
    @ModifyExpressionValue(
            method = "onPress",
            at = @At(
                    value = "INVOKE",
                    target = "Lnet/minecraft/client/gui/Gui;screen()Lnet/minecraft/client/gui/screens/Screen;"
            ),
            require = 1,
            remap = false
    )
    private Screen visorEssentials$allowEitherHandOutsideWorldContainer(Screen original) {
        return NativeContainerPlacement.isActive() ? null : original;
    }

    @ModifyExpressionValue(
            method = "process",
            at = @At(
                    value = "INVOKE",
                    target = "Lnet/minecraft/client/gui/Gui;screen()Lnet/minecraft/client/gui/screens/Screen;"
            ),
            require = 1,
            remap = false
    )
    private Screen visorEssentials$passClicksOutsideWorldContainer(Screen original) {
        return NativeContainerPlacement.isActive() ? null : original;
    }
}
