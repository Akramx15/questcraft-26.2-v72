package org.vmstudio.essentials.core.client.render;

import com.mojang.blaze3d.PrimitiveTopology;
import com.mojang.blaze3d.vertex.BufferBuilder;
import com.mojang.blaze3d.vertex.DefaultVertexFormat;
import com.mojang.blaze3d.vertex.PoseStack;
import com.mojang.math.Axis;
import me.phoenixra.atumvr.api.misc.color.AtumColorImmutable;
import net.minecraft.client.Minecraft;
import net.minecraft.util.Mth;
import net.minecraft.world.entity.player.Player;
import net.minecraft.world.phys.Vec3;
import org.jetbrains.annotations.NotNull;
import org.jetbrains.annotations.Nullable;
import org.joml.Matrix4f;
import org.joml.Vector3f;
import org.joml.Vector3fc;
import org.vmstudio.visor.api.ModLoader;
import org.vmstudio.visor.api.VisorAPI;
import org.vmstudio.visor.api.client.events.render.RenderPipelineStageVREvent;
import org.vmstudio.visor.api.client.player.VRClientPlayer;
import org.vmstudio.visor.api.client.player.pose.PlayerPoseType;
import org.vmstudio.visor.api.client.render.RenderPipelineStage;
import org.vmstudio.visor.api.common.addon.VisorAddon;
import org.vmstudio.visor.api.common.eventbus.listener.VREventHandler;
import org.vmstudio.visor.api.common.eventbus.listener.VREventListener;
import org.vmstudio.visor.api.common.player.VRPose;
import org.vmstudio.visor.core.client.render.VisorPipelines;
import org.vmstudio.visor.core.client.render.helpers.VRMeshDrawer;
import org.vmstudio.visor.core.client.render.helpers.VRTesselator;

import java.util.ArrayList;
import java.util.Comparator;
import java.util.List;

public class RemoteOverlayRenderHelper implements VREventListener {
    private static final String DISPLAY_TEXT = "OVERLAY";
    private static final AtumColorImmutable DISPLAY_COLOR =
            new AtumColorImmutable(40, 45, 60, 140);
    private static final AtumColorImmutable DISPLAY_TEXT_COLOR =
            new AtumColorImmutable(92, 100, 118, DISPLAY_COLOR.getAlphaInt());
    private static final float DISPLAY_WIDTH = 1.6f;
    private static final float DISPLAY_HEIGHT = 0.9f;
    private static final float DISPLAY_SIZE = 0.8f;
    private static final float DISPLAY_TEXT_SCALE = 0.01f;
    private static final float DISPLAY_TEXT_Z_OFFSET = 0.01f;
    private static final Comparator<OverlayRenderData> FARTHEST_FIRST =
            (left, right) -> compareDistanceFarthestFirst(
                    left.distanceToCameraSq(),
                    right.distanceToCameraSq()
            );

    public RemoteOverlayRenderHelper(@NotNull VisorAddon owner) {
        VisorAPI.eventBus().registerListener(owner, this);
        ModLoader.get().addToRenderPipeline(
                RenderPipelineStage.AFTER_TRANSLUCENT,
                this::renderWorld
        );
    }

    private static void render(@NotNull PoseStack poseStack,
                               @NotNull Vec3 cameraPos,
                               float partialTicks) {
        Minecraft minecraft = Minecraft.getInstance();
        if (minecraft.level == null || minecraft.player == null) {
            return;
        }

        // Most frames have no remote player focusing an overlay. Delay the
        // scratch-list allocation until a renderable entry actually exists.
        List<OverlayRenderData> overlays = null;

        for (Player player : minecraft.level.players()) {
            if (player == minecraft.player) {
                continue;
            }
            if (!player.isAlive() || player.isSleeping() || player.isInvisible()) {
                continue;
            }

            VRClientPlayer vrPlayer = VisorAPI.client().getVRPlayer(player.getUUID());
            if (vrPlayer == null || !vrPlayer.isOverlayFocused()) {
                continue;
            }

            VRPose hmdPose = vrPlayer.getPoseData(PlayerPoseType.RENDER).getHmd();
            RotationAngles rotationAngles = getOverlayRotation(player, hmdPose, partialTicks);
            Vector3f position = getIndicatorPosition(hmdPose, rotationAngles);
            double dx = position.x - cameraPos.x;
            double dy = position.y - cameraPos.y;
            double dz = position.z - cameraPos.z;
            overlays = appendOverlay(overlays, new OverlayRenderData(
                    position,
                    rotationAngles,
                    dx * dx + dy * dy + dz * dz
            ));
        }

        if (overlays == null) {
            return;
        }

        overlays.sort(FARTHEST_FIRST);

        for (OverlayRenderData overlay : overlays) {
            poseStack.pushPose();
            poseStack.translate(
                    overlay.position().x - cameraPos.x,
                    overlay.position().y - cameraPos.y,
                    overlay.position().z - cameraPos.z
            );
            poseStack.mulPose(Axis.YP.rotationDegrees(-overlay.rotationAngles().yaw()));
            poseStack.mulPose(Axis.XP.rotationDegrees(overlay.rotationAngles().pitch()));
            renderPlaceholderQuad(
                    poseStack.last().pose(),
                    DISPLAY_COLOR,
                    DISPLAY_WIDTH,
                    DISPLAY_HEIGHT,
                    DISPLAY_SIZE
            );
            poseStack.popPose();
        }
    }

    private static @NotNull Vector3f getIndicatorPosition(@NotNull VRPose hmdPose,
                                                          @NotNull RotationAngles rotationAngles) {
        Vec3 forward = Vec3.directionFromRotation(rotationAngles.pitch(), rotationAngles.yaw()).scale(0.45F);
        return new Vector3f(
                hmdPose.getPosition().x() + (float) forward.x,
                hmdPose.getPosition().y() + (float) forward.y,
                hmdPose.getPosition().z() + (float) forward.z
        );
    }

    @VREventHandler
    public void onRenderPipelineStage(@NotNull RenderPipelineStageVREvent event) {
        if (event.getStage() != RenderPipelineStage.AFTER_TRANSLUCENT
                || VisorAPI.clientState().stateMode().isNotActive()) {
            return;
        }

        VRPose cameraPose = VisorAPI.client()
                .getVRLocalPlayer()
                .getPoseData(PlayerPoseType.RENDER)
                .getCameraPose(event.getRenderPass());
        render(
                event.getPoseStack(),
                new Vec3(
                        cameraPose.getPosition().x(),
                        cameraPose.getPosition().y(),
                        cameraPose.getPosition().z()
                ),
                event.getPartialTicks()
        );
    }

    private static @NotNull RotationAngles getOverlayRotation(@NotNull Player player,
                                                              @NotNull VRPose hmdPose,
                                                              float partialTicks) {
        Vector3fc direction = hmdPose.getDirection();
        float horizontalLength = Mth.sqrt(direction.x() * direction.x() + direction.z() * direction.z());

        if (horizontalLength < 1.0E-4F) {
            float bodyYaw = Mth.rotLerp(partialTicks, player.yBodyRotO, player.yBodyRot);
            return new RotationAngles(bodyYaw, 0.0F);
        }

        float yaw = (float) Math.toDegrees(Mth.atan2(-direction.x(), direction.z()));
        float pitch = (float) Math.toDegrees(Mth.atan2(-direction.y(), horizontalLength));
        return new RotationAngles(yaw, pitch);
    }

    static <T> @NotNull List<T> appendOverlay(@Nullable List<T> overlays,
                                              @NotNull T overlay) {
        List<T> target = overlays;
        if (target == null) {
            target = new ArrayList<>();
        }
        target.add(overlay);
        return target;
    }

    static int compareDistanceFarthestFirst(double leftDistanceSq,
                                            double rightDistanceSq) {
        return Double.compare(rightDistanceSq, leftDistanceSq);
    }

    private static void renderPlaceholderQuad(@NotNull Matrix4f poseMatrix,
                                              @NotNull AtumColorImmutable color,
                                              float displayWidth,
                                              float displayHeight,
                                              float size) {
        float aspect = displayHeight / displayWidth;
        float halfSize = size * 0.5f;
        float halfHeight = halfSize * aspect;
        float[][] vertices = {
                {-halfSize, -halfHeight, 0f},
                {halfSize, -halfHeight, 0f},
                {halfSize, halfHeight, 0f},
                {-halfSize, halfHeight, 0f}
        };
        int[][] colors = new int[4][4];
        for (int[] vertexColor : colors) {
            vertexColor[0] = color.getRedInt();
            vertexColor[1] = color.getGreenInt();
            vertexColor[2] = color.getBlueInt();
            vertexColor[3] = color.getAlphaInt();
        }
        BufferBuilder buffer = VRTesselator.begin(
                PrimitiveTopology.QUADS, DefaultVertexFormat.POSITION_COLOR);
        emitColoredQuad(buffer, poseMatrix, vertices, colors, false);
        // The former RenderTypes.debugQuads path was two-sided. The current
        // depth-tested Visor pipeline culls, so submit the reverse winding too.
        emitColoredQuad(buffer, poseMatrix, vertices, colors, true);
        VRMeshDrawer.draw(VisorPipelines.POSITION_COLOR_TYPE, buffer.buildOrThrow());
    }

    private static void emitColoredQuad(@NotNull BufferBuilder buffer,
                                        @NotNull Matrix4f poseMatrix,
                                        float[][] vertices,
                                        int[][] colors,
                                        boolean reverse) {
        for (int step = 0; step < vertices.length; step++) {
            int index = reverse ? vertices.length - 1 - step : step;
            float[] vertex = vertices[index];
            int[] color = colors[index];
            buffer.addVertex(poseMatrix, vertex[0], vertex[1], vertex[2])
                    .setColor(color[0], color[1], color[2], color[3]);
        }
    }

    private void renderWorld(@NotNull PoseStack poseStack, float partialTicks) {
        if (VisorAPI.clientState().stateMode().isActive()) {
            return;
        }

        Minecraft minecraft = Minecraft.getInstance();
        if (minecraft.gameRenderer.mainCamera() == null) {
            return;
        }

        render(poseStack, minecraft.gameRenderer.mainCamera().position(), partialTicks);
    }

    private record RotationAngles(float yaw, float pitch) {}

    private record OverlayRenderData(@NotNull Vector3f position,
                                     @NotNull RotationAngles rotationAngles,
                                     double distanceToCameraSq) {
    }
}
