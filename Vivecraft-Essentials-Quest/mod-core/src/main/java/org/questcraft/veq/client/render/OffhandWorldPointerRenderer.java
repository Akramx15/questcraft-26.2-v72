package org.questcraft.veq.client.render;

import com.mojang.blaze3d.vertex.PoseStack;
import net.minecraft.client.Minecraft;
import net.minecraft.client.renderer.SubmitNodeCollector;
import net.minecraft.client.renderer.state.level.CameraRenderState;
import net.minecraft.client.renderer.texture.OverlayTexture;
import net.minecraft.client.renderer.texture.TextureAtlasSprite;
import net.minecraft.data.AtlasIds;
import net.minecraft.util.profiling.Profiler;
import org.questcraft.veq.client.input.OffhandWorldPointerState;
import org.questcraft.veq.mixin.HudAccessor;
import org.vivecraft.client_vr.render.renderstates.CrosshairRenderState;
import org.vivecraft.client_vr.render.rendertypes.VRRenderTypes;

/** Draws the independent offhand target as a smaller cyan Minecraft '+'. */
public final class OffhandWorldPointerRenderer {
    private static final float RED = 0.20F;
    private static final float GREEN = 0.90F;
    private static final float BLUE = 1.00F;

    private OffhandWorldPointerRenderer() {
    }

    public static void render(
            SubmitNodeCollector output,
            CameraRenderState cameraState,
            PoseStack poseStack
    ) {
        CrosshairRenderState state = OffhandWorldPointerState.renderState();
        if (!state.shouldRender || state.pos == null) {
            return;
        }

        Profiler.get().push("submit VEQ offhand pointer");
        poseStack.pushPose();
        poseStack.translate(
                state.pos.x - cameraState.pos.x,
                state.pos.y - cameraState.pos.y,
                state.pos.z - cameraState.pos.z);
        poseStack.mulPose(state.rotation);
        poseStack.scale(state.scale, state.scale, state.scale);

        TextureAtlasSprite sprite = Minecraft.getInstance().getAtlasManager()
                .getAtlasOrThrow(AtlasIds.GUI)
                .getSprite(HudAccessor.veq$getCrosshairSprite());
        float brightness = state.brightness;
        int light = state.light;
        // The normal pointer occupies order 0/1. Submit the offhand marker
        // immediately after it without needing a fragile local-variable capture.
        int order = state.occlude ? 1 : 2;
        output.order(order).submitCustomGeometry(
                poseStack,
                VRRenderTypes.crosshairWorld(sprite.atlasLocation(), !state.occlude),
                (pose, consumer) -> {
                    consumer.addVertex(pose, -1.0F, 1.0F, 0.0F)
                            .setColor(RED * brightness, GREEN * brightness, BLUE * brightness, 1.0F)
                            .setUv(sprite.getU1(), sprite.getV0())
                            .setOverlay(OverlayTexture.NO_OVERLAY).setLight(light)
                            .setNormal(0.0F, 0.0F, 1.0F);
                    consumer.addVertex(pose, 1.0F, 1.0F, 0.0F)
                            .setColor(RED * brightness, GREEN * brightness, BLUE * brightness, 1.0F)
                            .setUv(sprite.getU0(), sprite.getV0())
                            .setOverlay(OverlayTexture.NO_OVERLAY).setLight(light)
                            .setNormal(0.0F, 0.0F, 1.0F);
                    consumer.addVertex(pose, 1.0F, -1.0F, 0.0F)
                            .setColor(RED * brightness, GREEN * brightness, BLUE * brightness, 1.0F)
                            .setUv(sprite.getU0(), sprite.getV1())
                            .setOverlay(OverlayTexture.NO_OVERLAY).setLight(light)
                            .setNormal(0.0F, 0.0F, 1.0F);
                    consumer.addVertex(pose, -1.0F, -1.0F, 0.0F)
                            .setColor(RED * brightness, GREEN * brightness, BLUE * brightness, 1.0F)
                            .setUv(sprite.getU1(), sprite.getV1())
                            .setOverlay(OverlayTexture.NO_OVERLAY).setLight(light)
                            .setNormal(0.0F, 0.0F, 1.0F);
                });

        poseStack.popPose();
        Profiler.get().pop();
    }
}
