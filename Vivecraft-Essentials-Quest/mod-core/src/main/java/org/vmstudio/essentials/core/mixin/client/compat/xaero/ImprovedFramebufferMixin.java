package org.vmstudio.essentials.core.mixin.client.compat.xaero;

import com.mojang.blaze3d.pipeline.RenderTarget;
import net.minecraft.client.Minecraft;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.Pseudo;
import org.spongepowered.asm.mixin.Shadow;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.Inject;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfo;

/** Keeps Xaero's temporary framebuffer restoration scoped to each Visor target. */
@Pseudo
@Mixin(targets = {
        "xaero.map.graphics.ImprovedFramebuffer",
        "xaero.common.graphics.ImprovedFramebuffer"
}, remap = false)
public abstract class ImprovedFramebufferMixin {
    @Shadow(remap = false)
    private static RenderTarget mainRenderTargetBackup;

    @Inject(method = "forceAsMainRenderTarget", at = @At("HEAD"), require = 0, remap = false)
    private void visorEssentials$refreshDynamicMainTarget(CallbackInfo ci) {
        RenderTarget current = Minecraft.getInstance().gameRenderer.mainRenderTarget();
        if (!getClass().isInstance(current)) {
            mainRenderTargetBackup = null;
        }
    }
}
