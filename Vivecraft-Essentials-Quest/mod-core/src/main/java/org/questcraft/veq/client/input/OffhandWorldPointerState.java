package org.questcraft.veq.client.input;

import com.mojang.math.Axis;
import net.minecraft.client.Minecraft;
import net.minecraft.client.player.LocalPlayer;
import net.minecraft.core.BlockPos;
import net.minecraft.util.LightCoordsUtil;
import net.minecraft.world.InteractionHand;
import net.minecraft.world.phys.BlockHitResult;
import net.minecraft.world.phys.HitResult;
import net.minecraft.world.phys.Vec3;
import org.joml.Matrix4f;
import org.questcraft.veq.client.overlay.WristOverlayHandler;
import org.questcraft.veq.client.radial.RadialHotbarController;
import org.vivecraft.api.client.data.RenderPass;
import org.vivecraft.client_vr.ClientDataHolderVR;
import org.vivecraft.client_vr.VRData;
import org.vivecraft.client_vr.gameplay.screenhandlers.GuiHandler;
import org.vivecraft.client_vr.gameplay.screenhandlers.KeyboardHandler;
import org.vivecraft.client_vr.gameplay.screenhandlers.RadialHandler;
import org.vivecraft.client_vr.provider.ControllerType;
import org.vivecraft.client_vr.render.renderstates.CrosshairRenderState;
import org.vivecraft.client_vr.settings.VRSettings;

/**
 * Render-only logical-left/offhand target.
 *
 * <p>This state deliberately never reads or writes {@link Minecraft#hitResult};
 * the left trigger router and this marker share the same independent
 * {@link HandTargetSnapshot} raycast contract.</p>
 */
public final class OffhandWorldPointerState {
    private static final float POINTER_SCALE = 0.80F;
    private static final CrosshairRenderState RENDER_STATE = new CrosshairRenderState();

    private OffhandWorldPointerState() {
    }

    public static CrosshairRenderState renderState() {
        return RENDER_STATE;
    }

    /** Called alongside Vivecraft's normal crosshair extraction. */
    public static void extract(LocalPlayer player) {
        RENDER_STATE.shouldRender = false;
        Minecraft minecraft = Minecraft.getInstance();
        ClientDataHolderVR dataHolder = ClientDataHolderVR.getInstance();
        HandOwnershipSnapshot ownership = HandOwnershipSnapshot.capture(minecraft, dataHolder);
        HandOwnershipSnapshot.HandState left = ownership.hand(ControllerType.LEFT);
        // Do not evaluate render-pass, tracker or pose state when OpenXR has
        // not produced a complete logical-left sample for this frame.
        if (player == null || !ownership.runtimeReady() || left == null ||
                !left.tracking() || left.aimPose() == null) {
            return;
        }
        // VRRenderState invokes this extraction once during the first eye pass,
        // after VRPlayer.preRender has built a frame-current OpenXR pose. The
        // old tick pose made this marker visibly step at client tick cadence.
        VRData renderWorld = dataHolder.vrPlayer.getVRDataWorld();
        VRData.VRDevicePose renderAim = renderWorld.getController(
                QuestHandMapping.poseIndex(ControllerType.LEFT));
        if (renderAim == null) {
            return;
        }

        boolean handWorldAllowed = left.worldAllowed(true, ownership.bowOwnsBothHands());
        boolean pointerSettingAllows = dataHolder.vrSettings.renderInGameCrosshairMode !=
                VRSettings.RenderPointerElement.NEVER &&
                (dataHolder.vrSettings.renderInGameCrosshairMode !=
                        VRSettings.RenderPointerElement.WITH_HUD || !minecraft.gui.hud.isHidden());
        boolean gripShowing = RadialHotbarController.owns(ControllerType.LEFT) ||
                RadialHandler.isUsingController(ControllerType.LEFT);
        boolean worldScaleValid = dataHolder.vrPlayer != null &&
                dataHolder.vrPlayer.worldScale <= 15.0F;
        boolean shouldRender = player != null && OffhandWorldPointerPolicy.shouldRender(
                ownership.runtimeReady(),
                handWorldAllowed,
                true,
                pointerSettingAllows,
                dataHolder.currentPass != null && RenderPass.isFirstPerson(dataHolder.currentPass),
                dataHolder.viewOnly,
                KeyboardHandler.SHOWING,
                GuiHandler.GUI_POS_ROOM != null,
                minecraft.isPaused(),
                minecraft.gui.overlay() != null,
                WristOverlayHandler.isVisible(),
                gripShowing,
                dataHolder.teleportTracker.isAiming(),
                worldScaleValid);
        if (!shouldRender || minecraft.level == null) {
            return;
        }

        HandTargetSnapshot target = HandTargetSnapshot.capture(
                minecraft, player, ControllerType.LEFT, renderAim,
                InteractionHand.OFF_HAND, true);
        HitResult primary = target.primaryHit();
        if (primary == null) {
            return;
        }

        Vec3 renderPosition = primary.getLocation();
        // Reuse the immutable ray origin captured above; avoids a second
        // world-space pose conversion/allocation in the per-frame path.
        Vec3 crossDistance = renderPosition.subtract(target.start());
        if (crossDistance.lengthSqr() > 1.0E-8D) {
            renderPosition = renderPosition.add(crossDistance.normalize().scale(-0.01D));
        }
        RENDER_STATE.pos = renderPosition;

        Matrix4f rotation = RENDER_STATE.rotation.identity();
        if (primary instanceof BlockHitResult blockHit && primary.getType() == HitResult.Type.BLOCK) {
            switch (blockHit.getDirection()) {
                case DOWN -> {
                    rotation.rotate(Axis.YP.rotationDegrees(-renderAim.getYaw()));
                    rotation.rotate(Axis.XP.rotationDegrees(-90.0F));
                }
                case UP -> {
                    rotation.rotate(Axis.YP.rotationDegrees(-renderAim.getYaw()));
                    rotation.rotate(Axis.XP.rotationDegrees(90.0F));
                }
                case WEST -> rotation.rotate(Axis.YP.rotationDegrees(90.0F));
                case EAST -> rotation.rotate(Axis.YP.rotationDegrees(-90.0F));
                case SOUTH -> rotation.rotate(Axis.YP.rotationDegrees(180.0F));
            }
        } else {
            rotation.rotate(Axis.YP.rotationDegrees(-renderAim.getYaw()));
            rotation.rotate(Axis.XP.rotationDegrees(-renderAim.getPitch()));
        }

        float scale = (float) (0.125F * dataHolder.vrSettings.crosshairScale *
                Math.sqrt(renderWorld.worldScale));
        if (dataHolder.vrSettings.crosshairScalesWithDistance) {
            scale *= 0.3F + 0.2F * (float) crossDistance.length();
        }
        RENDER_STATE.scale = scale * POINTER_SCALE;
        RENDER_STATE.light = LightCoordsUtil.getLightCoords(
                player.level(), BlockPos.containing(RENDER_STATE.pos));
        RENDER_STATE.brightness = primary.getType() == HitResult.Type.MISS ? 0.55F : 1.0F;
        RENDER_STATE.occlude = dataHolder.vrSettings.useCrosshairOcclusion;
        RENDER_STATE.shouldRender = true;
    }
}
