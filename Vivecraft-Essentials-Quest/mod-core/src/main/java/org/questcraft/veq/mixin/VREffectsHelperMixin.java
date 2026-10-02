package org.questcraft.veq.mixin;

import com.mojang.blaze3d.vertex.PoseStack;
import net.minecraft.client.player.LocalPlayer;
import net.minecraft.client.renderer.SubmitNodeCollector;
import net.minecraft.client.renderer.SubmitNodeStorage;
import net.minecraft.client.renderer.state.level.LevelRenderState;
import org.questcraft.veq.client.input.OffhandWorldPointerState;
import org.questcraft.veq.client.render.OffhandWorldPointerRenderer;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.Inject;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfo;
import org.vivecraft.client_vr.render.helpers.VREffectsHelper;
import org.vivecraft.client_vr.render.renderstates.CrosshairRenderState;

/** Narrow render hooks; Vivecraft's normal right/main crosshair is untouched. */
@Mixin(VREffectsHelper.class)
public abstract class VREffectsHelperMixin {
    private static final String CROSSHAIR_RENDER_TARGET =
            "Lorg/vivecraft/client_vr/render/helpers/VREffectsHelper;" +
                    "renderCrosshairAtDepth(" +
                    "Lnet/minecraft/client/renderer/SubmitNodeCollector;" +
                    "Lorg/vivecraft/client_vr/render/renderstates/CrosshairRenderState;" +
                    "Lnet/minecraft/client/renderer/state/level/CameraRenderState;" +
                    "Lcom/mojang/blaze3d/vertex/PoseStack;I)I";

    @Inject(method = "extractCrosshairState", at = @At("RETURN"))
    private static void veq$extractOffhandPointer(
            CrosshairRenderState crosshairState,
            LocalPlayer player,
            CallbackInfo callback
    ) {
        OffhandWorldPointerState.extract(player);
    }

    @Inject(
            method = "renderVRFabulous",
            at = @At(value = "INVOKE", target = CROSSHAIR_RENDER_TARGET, shift = At.Shift.AFTER)
    )
    private static void veq$renderOffhandPointerFabulous(
            SubmitNodeStorage output,
            LevelRenderState levelState,
            PoseStack poseStack,
            CallbackInfo callback
    ) {
        OffhandWorldPointerRenderer.render(output, levelState.cameraRenderState, poseStack);
    }

    @Inject(
            method = "renderVrFast",
            at = @At(value = "INVOKE", target = CROSSHAIR_RENDER_TARGET, shift = At.Shift.AFTER)
    )
    private static void veq$renderOffhandPointerFast(
            SubmitNodeCollector output,
            LevelRenderState levelState,
            PoseStack poseStack,
            boolean secondPassOnly,
            CallbackInfo callback
    ) {
        OffhandWorldPointerRenderer.render(output, levelState.cameraRenderState, poseStack);
    }
}
