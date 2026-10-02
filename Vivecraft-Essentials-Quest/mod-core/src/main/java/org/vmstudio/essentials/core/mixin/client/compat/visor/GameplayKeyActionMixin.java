package org.vmstudio.essentials.core.mixin.client.compat.visor;

import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.Pseudo;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.Redirect;
import org.vmstudio.essentials.core.client.gui.KeyboardWorldInputScope;
import org.vmstudio.visor.api.client.input.InputHelper;

/** Scopes native-screen transparency to Visor's jump and crouch actions. */
@Pseudo
@Mixin(
        targets = {
                "org.vmstudio.visor.core.client.input.actions.game.GameActionJump",
                "org.vmstudio.visor.core.client.input.actions.ActionShift"
        },
        remap = false
)
public abstract class GameplayKeyActionMixin {
    @Redirect(
            method = "onPress",
            at = @At(
                    value = "INVOKE",
                    target = "Lorg/vmstudio/visor/api/client/input/InputHelper;pressKey(I)V"
            ),
            require = 1,
            remap = false
    )
    private void visorEssentials$routeGameplayKeyPress(int key) {
        KeyboardWorldInputScope.run(() -> InputHelper.pressKey(key));
    }

    @Redirect(
            method = "onRelease",
            at = @At(
                    value = "INVOKE",
                    target = "Lorg/vmstudio/visor/api/client/input/InputHelper;releaseKey(I)V"
            ),
            require = 1,
            remap = false
    )
    private void visorEssentials$routeGameplayKeyRelease(int key) {
        KeyboardWorldInputScope.run(() -> InputHelper.releaseKey(key));
    }
}
