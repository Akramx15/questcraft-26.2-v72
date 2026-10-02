package org.vmstudio.essentials.core.mixin.client.compat.xaero;

import com.mojang.blaze3d.pipeline.BlendFunction;
import com.mojang.blaze3d.platform.BlendFactor;
import org.objectweb.asm.Opcodes;
import org.spongepowered.asm.mixin.Final;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.Mutable;
import org.spongepowered.asm.mixin.Pseudo;
import org.spongepowered.asm.mixin.Shadow;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.Redirect;

/** Preserves opaque map color while accumulating alpha into Visor's GUI target. */
@Pseudo
@Mixin(targets = "xaero.lib.client.graphics.XaeroRenderType", remap = false)
public abstract class XaeroRenderTypeMixin {
    @Shadow(remap = false) @Final @Mutable
    protected static BlendFunction DEST_TRANSPARENCY;

    @Redirect(
            method = "<clinit>",
            at = @At(
                    value = "FIELD",
                    target = "Lxaero/lib/client/graphics/XaeroRenderType;DEST_TRANSPARENCY:Lcom/mojang/blaze3d/pipeline/BlendFunction;",
                    opcode = Opcodes.PUTSTATIC
            ),
            require = 0,
            remap = false
    )
    private static void visorEssentials$fixMapDestinationAlpha(BlendFunction ignored) {
        DEST_TRANSPARENCY = new BlendFunction(
                BlendFactor.ONE,
                BlendFactor.ZERO,
                BlendFactor.ONE,
                BlendFactor.ONE_MINUS_SRC_ALPHA
        );
    }
}
