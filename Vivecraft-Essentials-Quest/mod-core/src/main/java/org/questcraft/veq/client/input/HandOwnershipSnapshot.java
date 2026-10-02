package org.questcraft.veq.client.input;

import net.minecraft.client.Minecraft;
import org.questcraft.veq.client.overlay.WristOverlayHandler;
import org.vivecraft.client_vr.ClientDataHolderVR;
import org.vivecraft.client_vr.VRData;
import org.vivecraft.client_vr.VRState;
import org.vivecraft.client_vr.gameplay.screenhandlers.ExternalScreenOverlayHandler;
import org.vivecraft.client_vr.gameplay.screenhandlers.RadialHandler;
import org.vivecraft.client_vr.provider.ControllerType;

import java.util.EnumMap;

/** Immutable per-tick ownership and logical Aim-pose view for both hands. */
public final class HandOwnershipSnapshot {
    private final boolean runtimeReady;
    private final boolean bowOwnsBothHands;
    private final EnumMap<ControllerType, HandState> hands;

    private HandOwnershipSnapshot(
            boolean runtimeReady,
            boolean bowOwnsBothHands,
            EnumMap<ControllerType, HandState> hands
    ) {
        this.runtimeReady = runtimeReady;
        this.bowOwnsBothHands = bowOwnsBothHands;
        this.hands = hands;
    }

    public static HandOwnershipSnapshot capture(
            Minecraft minecraft,
            ClientDataHolderVR dataHolder
    ) {
        boolean ready = runtimeReady(minecraft, dataHolder);
        boolean bowOwns = ready &&
                (dataHolder.bowTracker.isNotched() || dataHolder.bowTracker.isDrawing());
        EnumMap<ControllerType, HandState> states = new EnumMap<>(ControllerType.class);
        for (ControllerType controller : ControllerType.values()) {
            boolean tracking = ready && dataHolder.vr.isControllerTracking(controller);
            VRData.VRDevicePose aimPose = tracking
                    ? dataHolder.vrPlayer.vrdata_world_pre.getController(
                            QuestHandMapping.poseIndex(controller))
                    : null;
            HandActionPriority.Owner owner = ready
                    ? resolveOwner(controller, bowOwns)
                    : HandActionPriority.Owner.WRIST;
            states.put(controller, new HandState(controller, tracking, aimPose, owner));
        }
        return new HandOwnershipSnapshot(ready, bowOwns, states);
    }

    public boolean runtimeReady() {
        return this.runtimeReady;
    }

    public boolean bowOwnsBothHands() {
        return this.bowOwnsBothHands;
    }

    public HandState hand(ControllerType controller) {
        return this.hands.get(controller);
    }

    static boolean worldAllowed(
            boolean runtimeReady,
            boolean tracking,
            boolean poseValid,
            HandActionPriority.Owner owner,
            boolean bowOwnsBothHands
    ) {
        return runtimeReady && tracking && poseValid &&
                owner == HandActionPriority.Owner.WORLD && !bowOwnsBothHands;
    }

    private static boolean runtimeReady(Minecraft minecraft, ClientDataHolderVR dataHolder) {
        return VRState.VR_RUNNING && minecraft.player != null && minecraft.level != null &&
                minecraft.gameMode != null && minecraft.gui.screen() == null &&
                dataHolder.vr != null && !dataHolder.vrSettings.seated &&
                dataHolder.vrPlayer != null && dataHolder.vrPlayer.vrdata_world_pre != null;
    }

    private static HandActionPriority.Owner resolveOwner(
            ControllerType controller,
            boolean bowOwnsBothHands
    ) {
        boolean immersiveFocused = GripRuntimeGate.interactionModuleActive(controller) ||
                GripRuntimeGate.immersiveMcOwnsInput(controller);
        return HandActionPriority.choose(
                WristOverlayHandler.isPointerFocused(controller) ||
                        GripRuntimeGate.wristCalibrationOwnsHands(),
                bowOwnsBothHands,
                immersiveFocused,
                GripRuntimeGate.climbingOwnsInput(controller),
                ExternalScreenOverlayHandler.isUsingController(controller) ||
                        (RadialHandler.isShowing() &&
                                RadialHandler.getActiveController() == controller)
        );
    }

    public record HandState(
            ControllerType controller,
            boolean tracking,
            VRData.VRDevicePose aimPose,
            HandActionPriority.Owner owner
    ) {
        public boolean worldAllowed(boolean runtimeReady, boolean bowOwnsBothHands) {
            return HandOwnershipSnapshot.worldAllowed(
                    runtimeReady, this.tracking, this.aimPose != null, this.owner,
                    bowOwnsBothHands);
        }
    }
}
