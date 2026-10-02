package org.vmstudio.essentials.core.mixin.client.gui;

import net.minecraft.client.gui.GuiGraphicsExtractor;
import net.minecraft.client.gui.screens.Screen;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.Inject;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfo;
import org.vmstudio.essentials.core.client.extensions.AbstractContainerScreenExtension;
import org.vmstudio.essentials.core.client.gui.NativeContainerPlacement;

/** Removes only the full-screen world dim behind an in-world container. */
@Mixin(Screen.class)
public abstract class ScreenBackgroundMixin {

    @Inject(method = "extractBackground", at = @At("HEAD"), cancellable = true)
    private void visorEssentials$skipContainerOverlayWorldDim(
            GuiGraphicsExtractor graphics, int mouseX, int mouseY,
            float partialTick, CallbackInfo ci) {
        if ((Object) this instanceof AbstractContainerScreenExtension extension
                && (extension.visorEssentials$isVRContainer()
                || NativeContainerPlacement.isActiveFor((Screen) (Object) this))) {
            ci.cancel();
        }
    }
}
