package org.questcraft.veq.mixin;

import com.llamalad7.mixinextras.injector.ModifyExpressionValue;
import org.questcraft.veq.client.input.ExternalOverlayActionSetPolicy;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.injection.At;
import org.vivecraft.client_vr.gameplay.screenhandlers.ExternalScreenOverlayHandler;
import org.vivecraft.client_vr.provider.openxr.MCOpenXR;

/**
 * Keeps the handed keyboard-click action available while an in-world external
 * surface owns pointer input. The normal GUI action set is inactive in-world,
 * so without this gate hover works but trigger presses never reach the surface.
 */
@Mixin(MCOpenXR.class)
public abstract class MCOpenXRActionSetMixin {
    @ModifyExpressionValue(
            method = "updateActiveActionSets",
            at = @At(
                    value = "FIELD",
                    target = "Lorg/vivecraft/client_vr/gameplay/screenhandlers/KeyboardHandler;SHOWING:Z"
            )
    )
    private boolean veq$activateKeyboardSetForExternalPointer(boolean keyboardShowing) {
        return ExternalOverlayActionSetPolicy.keyboardSetActive(
                keyboardShowing,
                ExternalScreenOverlayHandler.ownsPointerInput()
        );
    }
}
