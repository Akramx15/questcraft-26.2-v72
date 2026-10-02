package org.vmstudio.essentials.core.mixin.client;

import com.llamalad7.mixinextras.injector.ModifyExpressionValue;
import net.minecraft.client.KeyboardHandler;
import net.minecraft.client.gui.screens.Screen;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.injection.At;
import org.vmstudio.essentials.core.client.gui.KeyboardWorldInputScope;

/**
 * Makes only scoped Visor jump/crouch events bypass an anchored Screen. Text,
 * hotkeys, IPN, JEI, and every ordinary keyboard event keep the native path.
 */
@Mixin(KeyboardHandler.class)
public abstract class KeyboardHandlerMixin {
    @ModifyExpressionValue(
            method = "keyPress",
            at = @At(
                    value = "INVOKE",
                    target = "Lnet/minecraft/client/gui/Gui;screen()Lnet/minecraft/client/gui/screens/Screen;"
            ),
            require = 5
    )
    private Screen visorEssentials$routeScopedGameplayKey(Screen original) {
        return KeyboardWorldInputScope.isRouting() ? null : original;
    }
}
