package org.questcraft.veq.client.input;

import net.minecraft.client.Minecraft;
import org.questcraft.veq.client.config.WristUiConfig;
import org.questcraft.veq.client.overlay.WristOverlayHandler;
import org.questcraft.veq.mixin.InteractTrackerAccessor;
import org.vivecraft.api.client.InteractModule;
import org.vivecraft.client.VivecraftVRMod;
import org.vivecraft.client_vr.ClientDataHolderVR;
import org.vivecraft.client_vr.provider.ControllerType;
import org.vivecraft.client_vr.provider.openvr_lwjgl.VRInputAction;

public final class GripRuntimeGate {
    private static final GripReleaseLatch CALIBRATION_RELEASE = new GripReleaseLatch();

    private GripRuntimeGate() {
    }

    public static boolean isClimbingLatched() {
        return ClientDataHolderVR.getInstance().climbTracker.isGrabbingLadder();
    }

    public static boolean isClimbingLatched(ControllerType controller) {
        return controller != null &&
                ClientDataHolderVR.getInstance().climbTracker.isGrabbingLadder(controller.ordinal());
    }

    public static boolean allowRadial(ControllerType controller) {
        // Offhand SWAP reconciliation is passive. It must never globally lock
        // either hand's independent Grip surface; the transaction layer alone
        // rejects a second LEFT SWAP until the first is server-confirmed.
        return allowRadialContinuation(controller);
    }

    /**
     * Re-arbitrates an already open Grip surface.
     *
     * <p>Wrist/ImmersiveMC/climbing/bow and lifecycle owners can take this
     * exact hand immediately without closing the other hand's surface.</p>
     */
    public static boolean allowRadialContinuation(ControllerType controller) {
        pollReleaseGates();
        if (WristOverlayHandler.isCalibrating()) {
            return false;
        }
        // Missing action origins fail closed. Falling back to RIGHT was the
        // source of the v62 left-Grip/main-hand regression.
        if (controller == null) {
            return false;
        }
        if (CALIBRATION_RELEASE.isSuppressed(controller)) {
            return false;
        }
        ClientDataHolderVR dataHolder = ClientDataHolderVR.getInstance();
        Minecraft minecraft = Minecraft.getInstance();
        boolean lifecycleReady = dataHolder.vr != null && minecraft.player != null &&
                minecraft.level != null && !dataHolder.vrSettings.seated &&
                dataHolder.vrPlayer != null && dataHolder.vrPlayer.vrdata_world_pre != null &&
                minecraft.gui.screen() == null && !minecraft.isPaused() && minecraft.player.isAlive();
        if (!lifecycleReady) {
            return false;
        }
        // Merely holding an unnotched bow must not steal Grip/offhand. The bow
        // owns both hands only while its interaction module is actually armed.
        boolean bowOwnsGrip = dataHolder.bowTracker.isNotched() || dataHolder.bowTracker.isDrawing();

        boolean wristFocused = WristOverlayHandler.isPointerFocused(controller) ||
                wristCalibrationOwnsHands();
        boolean moduleActive = interactionModuleActive(controller) || immersiveMcOwnsInput(controller);
        boolean climbingOwnsGrip = climbingOwnsInput(controller);
        return RadialContinuationPolicy.keepOpen(
                true,
                dataHolder.vr.isControllerTracking(controller),
                wristFocused,
                moduleActive,
                climbingOwnsGrip,
                bowOwnsGrip,
                WristUiConfig.getInstance().radialHotbarEnabled()
        );
    }

    public static boolean wristCalibrationOwnsHands() {
        return WristCalibrationOwnership.ownsHands();
    }

    /** Called every client tick and immediately before opening a radial. */
    public static void pollReleaseGates() {
        if (WristCalibrationOwnership.pollEnded()) {
            CALIBRATION_RELEASE.suppressBoth();
        }
        ClientDataHolderVR dataHolder = ClientDataHolderVR.getInstance();
        for (ControllerType controller : ControllerType.values()) {
            CALIBRATION_RELEASE.observe(controller, sampleRadial(dataHolder, controller));
        }
    }

    static void clearForVrShutdown() {
        CALIBRATION_RELEASE.clearForShutdown();
    }

    private static GripReleaseLatch.Sample sampleRadial(
            ClientDataHolderVR dataHolder,
            ControllerType controller
    ) {
        if (dataHolder.vr == null) {
            return GripReleaseLatch.Sample.UNKNOWN;
        }
        VRInputAction action = dataHolder.vr.getInputAction(VivecraftVRMod.INSTANCE.keyRadialMenu);
        if (action == null || !action.isHanded() || !action.isEnabledRaw(controller) ||
                !action.isActive(controller)) {
            return GripReleaseLatch.Sample.UNKNOWN;
        }
        long origin = action.getLastOrigin(controller);
        if (origin == 0L || dataHolder.vr.getOriginControllerType(origin) != controller) {
            return GripReleaseLatch.Sample.UNKNOWN;
        }
        return action.isButtonPressed(controller)
                ? GripReleaseLatch.Sample.DOWN
                : GripReleaseLatch.Sample.RELEASED;
    }

    public static boolean interactionModuleActive(ControllerType controller) {
        if (controller == null) {
            return false;
        }
        ClientDataHolderVR dataHolder = ClientDataHolderVR.getInstance();
        InteractModule[] modules = ((InteractTrackerAccessor) dataHolder.interactTracker)
                .veq$getActiveModules();
        // InteractTracker stores its active modules in ControllerType.values() order.
        int index = controller.ordinal();
        return index >= 0 && index < modules.length && modules[index] != null;
    }

    public static boolean immersiveMcOwnsInput(ControllerType controller) {
        ClientDataHolderVR dataHolder = ClientDataHolderVR.getInstance();
        if (controller == null || dataHolder.vrPlayer == null ||
                dataHolder.vrPlayer.vrdata_world_pre == null) {
            return false;
        }
        var pose = dataHolder.vrPlayer.vrdata_world_pre.getController(controller.ordinal());
        return pose != null && ImmersiveMcInputAdapter.claimsHand(
                QuestHandMapping.interactionHand(controller),
                pose.getPosition());
    }

    public static boolean climbingOwnsInput(ControllerType controller) {
        if (controller == null) {
            return false;
        }
        ClientDataHolderVR dataHolder = ClientDataHolderVR.getInstance();
        // ClimbTracker.isActive(player) is only an eligibility check and is
        // commonly true while standing still. The raw climb action is the
        // narrower ownership signal: Vivecraft enables it for this controller
        // when a manual climb can grab, is latched, or is in its short
        // post-release transition. Auto-grab is covered by the latch state.
        var climbAction = dataHolder.vr == null
                ? null
                : dataHolder.vr.getInputAction(VivecraftVRMod.INSTANCE.keyClimbeyGrab);
        return ClimbGripState.claimsGrip(
                isClimbingLatched(controller),
                climbAction != null && climbAction.isEnabledRaw(controller) &&
                        VivecraftVRMod.INSTANCE.keyClimbeyGrab.isDown(controller)
        );
    }
}
