package org.questcraft.veq.client.wrist;

import net.minecraft.client.Minecraft;
import net.minecraft.client.player.LocalPlayer;
import org.questcraft.veq.client.config.WristUiConfig;
import org.questcraft.veq.client.gui.WristSettingsScreen;
import org.questcraft.veq.client.overlay.WristOverlayHandler;
import org.vivecraft.api.client.Tracker;
import org.vivecraft.api.client.VRClientAPI;
import org.vivecraft.client_vr.ClientDataHolderVR;
import org.vivecraft.client_vr.VRData;
import org.vivecraft.client_vr.provider.MCVR;

public final class WristInventoryTracker implements Tracker {
    private final Minecraft minecraft = Minecraft.getInstance();
    private final VepSurfaceVisibilityPolicy visibility = new VepSurfaceVisibilityPolicy();

    @Override
    public ProcessType processType() {
        // The panel is anchored to a tracked controller, so update it from the
        // latest room pose before every rendered frame instead of at 20 Hz.
        return ProcessType.PER_FRAME;
    }

    @Override
    public boolean isActive(LocalPlayer player) {
        WristUiConfig config = WristUiConfig.getInstance();
        boolean editingPose = minecraft.gui.screen() instanceof WristSettingsScreen
                && WristOverlayHandler.isCalibrating();
        if ((!config.enabled() && !editingPose)
                || player == null
                || !player.isAlive()
                || player.isSleeping()
                || minecraft.isPaused()
                || VRClientAPI.instance().isSeated()) {
            return false;
        }
        if (minecraft.gui.screen() != null && !(minecraft.gui.screen() instanceof WristSettingsScreen)) {
            return false;
        }
        int anchorIndex = config.hand().controllerIndex();
        // The opposite hand is an optional pointer, not an anchor. Requiring
        // both controllers here hid the whole inventory on a single-frame
        // tracking loss even though the wrist pose was still valid.
        return MCVR.get().isControllerTracking(anchorIndex);
    }

    @Override
    public void activeProcess(LocalPlayer player) {
        WristUiConfig config = WristUiConfig.getInstance();
        VRData roomPose = ClientDataHolderVR.getInstance().vrPlayer.vrdata_room_pre;
        if (roomPose == null || roomPose.hmd == null) {
            closeAndReset();
            return;
        }
        // The wrist surface is a UI pointer surface, so it follows the logical
        // AIM pose. Grip remains reserved for held tools and bow interaction.
        VRData.VRDevicePose aim = roomPose.getController(config.hand().controllerIndex());
        if (aim == null) {
            closeAndReset();
            return;
        }

        // Keep the candidate pose current even while hidden. This lets the
        // opposite controller acquire the exact panel bounds, as VEP does,
        // instead of requiring the wrist gesture to open it first.
        WristOverlayHandler.updateRoomPose(config, aim);

        if (WristOverlayHandler.isCalibrating()) {
            WristOverlayHandler.setVisible(true);
            return;
        }

        boolean shouldShow = WristOverlayHandler.updateVisibility(
                this.visibility,
                roomPose.hmd,
                System.currentTimeMillis(),
                config.openDelayMillis(),
                config.closeDelayMillis()
        );

        boolean wasShowing = WristOverlayHandler.isVisible();
        WristOverlayHandler.setVisible(shouldShow);
        if (shouldShow && !wasShowing) {
            VRClientAPI.instance().triggerHapticPulse(
                    config.hand().interactionHand() == net.minecraft.world.InteractionHand.MAIN_HAND
                            ? org.vivecraft.api.data.VRBodyPart.MAIN_HAND
                            : org.vivecraft.api.data.VRBodyPart.OFF_HAND,
                    0.025F
            );
        }
    }

    @Override
    public void inactiveProcess(LocalPlayer player) {
        closeAndReset();
    }

    private void closeAndReset() {
        visibility.reset();
        WristOverlayHandler.forceHide();
    }
}
