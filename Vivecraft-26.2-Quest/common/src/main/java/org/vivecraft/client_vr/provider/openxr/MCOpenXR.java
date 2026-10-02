package org.vivecraft.client_vr.provider.openxr;

import com.mojang.blaze3d.platform.InputConstants;
import net.minecraft.client.KeyMapping;
import net.minecraft.client.Minecraft;
import net.minecraft.util.Mth;
import net.minecraft.util.profiling.Profiler;
import org.apache.commons.lang3.tuple.Pair;
import org.joml.Matrix4f;
import org.joml.Matrix4fc;
import org.joml.Quaternionf;
import org.joml.Vector2f;
import org.joml.Vector3f;
import org.lwjgl.PointerBuffer;
import org.lwjgl.opengl.GL11;
import org.lwjgl.opengl.GL21;
import org.lwjgl.opengl.GL30;
import org.lwjgl.opengl.GL31;
import org.lwjgl.openvr.VR;
import org.lwjgl.openxr.*;
import org.lwjgl.system.MemoryStack;
import org.lwjgl.system.MemoryUtil;
import org.vivecraft.api.client.data.RenderPass;
import org.vivecraft.client.VivecraftVRMod;
import org.vivecraft.client_vr.ClientDataHolderVR;
import org.vivecraft.client_vr.VRState;
import org.vivecraft.client_vr.gameplay.screenhandlers.GuiHandler;
import org.vivecraft.client_vr.gameplay.screenhandlers.KeyboardHandler;
import org.vivecraft.client_vr.gameplay.screenhandlers.NativeContainerAxisLatch;
import org.vivecraft.client_vr.gameplay.screenhandlers.NativeContainerFreshPressLatch;
import org.vivecraft.client_vr.gameplay.screenhandlers.RadialHandler;
import org.vivecraft.client_vr.provider.ControllerType;
import org.vivecraft.client_vr.provider.InputSimulator;
import org.vivecraft.client_vr.provider.MCVR;
import org.vivecraft.client_vr.provider.VRRenderer;
import org.vivecraft.client_vr.provider.openvr_lwjgl.VRInputAction;
import org.vivecraft.client_vr.provider.openvr_lwjgl.control.TrackpadSwipeSampler;
import org.vivecraft.client_vr.provider.openvr_lwjgl.control.VRInputActionSet;
import org.vivecraft.client_vr.render.RenderConfigException;
import org.vivecraft.client_vr.render.helpers.graphics.GraphicsHelper;
import org.vivecraft.client_vr.render.helpers.graphics.OpenGLHelper;
import org.vivecraft.client_vr.settings.VRSettings;
import org.vivecraft.common.utils.MathUtils;

import javax.annotation.Nullable;
import java.nio.ByteBuffer;
import java.nio.IntBuffer;
import java.nio.LongBuffer;
import java.util.*;
import java.util.concurrent.locks.LockSupport;

import static org.lwjgl.opengl.GL30.GL_FRAMEBUFFER_SRGB;
import static org.lwjgl.system.MemoryStack.*;
import static org.lwjgl.system.MemoryUtil.*;

public class MCOpenXR extends MCVR {

    private static MCOpenXR OME;
    public XrInstance instance;
    public XrSession session;
    public XrSpace xrAppSpace;
    public XrSpace xrViewSpace;
    public XrSwapchain[] swapchain;
    public final XrEventDataBuffer eventDataBuffer = XrEventDataBuffer.calloc();
    public long time;
    private boolean tried;
    private long systemID;
    public XrView.Buffer viewBuffer;
    public int width;
    public int height;
    // TODO either move to MCVR, Or make special for OpenXR holding the instance itself.
    private final Map<VRInputActionSet, Long> actionSetHandles = new EnumMap<>(VRInputActionSet.class);
    private final Map<VRInputActionSet, XrActionSet> actionSets = new EnumMap<>(VRInputActionSet.class);
    private final Map<VRInputAction, XrAction> inputActionHandles = new IdentityHashMap<>();
    // TODO Move to MCVR
    private XrActiveActionSet.Buffer activeActionSetsBuffer;
    private final Map<VRInputActionSet, Set<VRInputAction>> unpressedSetKeys =
        new EnumMap<>(VRInputActionSet.class);
    private ArrayList<VRInputActionSet> activeActionSets = new ArrayList<>();
    private ArrayList<VRInputActionSet> pendingActionSets = new ArrayList<>();
    private final Map<String, TrackpadSwipeSampler> trackpadSwipeSamplers = new HashMap<>();
    private final NativeContainerAxisLatch nativeContainerAxisLatch = new NativeContainerAxisLatch();
    private final NativeContainerFreshPressLatch<VRInputAction> nativeContainerFreshPressLatch =
        new NativeContainerFreshPressLatch<>();
    private boolean nativeContainerWorldAxesSuppressed;
    private final Map<Long, long[]> actionOrigins = new HashMap<>();
    private final Map<Long, ControllerType> originControllerTypes = new HashMap<>();
    private boolean isActive;
    private boolean sessionRunning;
    private int sessionState = 0;
    private final QuestOpenXRBackgroundPolicy backgroundPolicy;
    private boolean stoppedSessionThrottleActive;
    private long stoppedSessionThrottleTransition;
    private final HashMap<String, Long> paths = new HashMap<>();
    private final long[] grip = new long[2];
    private final long[] aim = new long[2];
    private final XrAction[] gripActions = new XrAction[2];
    private final XrAction[] aimActions = new XrAction[2];
    private final XrAction[] hapticActions = new XrAction[2];
    private final XrSpace[] gripSpace = new XrSpace[2];
    private final XrSpace[] aimSpace = new XrSpace[2];
    private final Matrix4f[] rawGripPose = {new Matrix4f(), new Matrix4f()};
    private final Matrix4f[] rawAimPose = {new Matrix4f(), new Matrix4f()};
    private final Matrix4f[] inverseAimScratch = {new Matrix4f(), new Matrix4f()};
    private final Matrix4f[] aimToGripTransform = {new Matrix4f(), new Matrix4f()};
    private final Matrix4f identityComponentTransform = new Matrix4f();
    private final boolean[] gripActionActive = new boolean[2];
    private final boolean[] aimActionActive = new boolean[2];
    private final boolean[] gripPoseValid = new boolean[2];
    private final boolean[] aimPoseValid = new boolean[2];
    private final long[] gripPoseFrame = {-1L, -1L};
    private final long[] aimPoseFrame = {-1L, -1L};
    private final long[] gripPoseTime = {0L, 0L};
    private final long[] aimPoseTime = {0L, 0L};
    private final long[] gripLocationFlags = new long[2];
    private final long[] aimLocationFlags = new long[2];
    private final OpenXRInputPollingBuffers inputPollingBuffers = new OpenXRInputPollingBuffers();
    private final Matrix4f inverseHeadPose = new Matrix4f();
    private final Matrix4f absoluteEyePose = new Matrix4f();
    private final Vector3f controllerTipDirection = new Vector3f();
    private final Vector3f controllerHandDirection = new Vector3f();
    public static final XrPosef POSE_IDENTITY = XrPosef.calloc().set(
        XrQuaternionf.calloc().set(0, 0, 0, 1),
        XrVector3f.calloc()
    );
    public boolean shouldRender = true;
    public long[] haptics = new long[2];
    public String systemName;
    public boolean frameBegun;
    private boolean inputInitialized;
    private final Set<String> enabledInstanceExtensions = new HashSet<>();
    private int appSpaceType = XR10.XR_REFERENCE_SPACE_TYPE_STAGE;
    private long trackingFrameCount;
    private long inputFrameCount;
    private int inputChangeLogCount;
    private boolean reverseHandsForFrame;
    protected static final DeviceCompat device = DeviceCompat.detectDevice();
    private static final String[] BOTH_HANDS = {
        VR.k_pchPathUserHandLeft,
        VR.k_pchPathUserHandRight
    };
    private static final ControllerType[] CONTROLLERS = ControllerType.values();
    private static final int UNHANDED_INPUT_SLOT = 1;
    private static final int ALL_HANDED_INPUT_SLOTS = (1 << CONTROLLERS.length) - 1;
    private static final String[] GRIP_SPACE_LABELS = {"gripSpace[right]", "gripSpace[left]"};
    private static final String[] AIM_SPACE_LABELS = {"aimSpace[right]", "aimSpace[left]"};

    public MCOpenXR(Minecraft mc, ClientDataHolderVR dh) {
        super(mc, dh, VivecraftVRMod.INSTANCE);
        OME = this;
        this.backgroundPolicy = new QuestOpenXRBackgroundPolicy(
            device instanceof DeviceCompat.Mobile,
            System.getProperty("user.dir", ""));
        this.hapticScheduler = new OpenXRHapticScheduler();
        for (VRInputActionSet set : VRInputActionSet.values()) {
            this.unpressedSetKeys.put(set, new HashSet<>());
        }
        if (GraphicsHelper.INSTANCE instanceof OpenGLHelper) {
            GL11.glDisable(GL_FRAMEBUFFER_SRGB);
        }
    }

    @Override
    public String getName() {
        return "OpenXR";
    }

    @Override
    public void processInputs() {
        if (this.dh.vrSettings.seated || this.dh.viewOnly || !this.inputInitialized || !this.sessionRunning) {
            this.ignorePressesNextFrame = false;
            // Home/Guardian can suspend OpenXR while a container is open.
            // Preserve the handoff until the physical world axes are observed
            // neutral after resume instead of failing open.
            this.nativeContainerAxisLatch.suspend();
            this.nativeContainerWorldAxesSuppressed = this.nativeContainerAxisLatch.isSuppressed();
            return;
        }

        boolean nativeContainer = this.isNativeContainerLocomotionActive();
        this.nativeContainerWorldAxesSuppressed = this.nativeContainerAxisLatch.update(
            nativeContainer,
            this.isAxisNeutral(GuiHandler.KEY_SCROLL_AXIS),
            !nativeContainer && this.areContainerWorldAxesNeutral());
        if (this.nativeContainerAxisLatch.transitioned()) {
            this.trackpadSwipeSamplers.clear();
        }
        if (this.nativeContainerAxisLatch.exited()) {
            this.requireFreshWorldPresses();
        }

        long frame = ++this.inputFrameCount;
        int activeStates = 0;
        int pressedStates = 0;
        int changedStates = 0;
        for (VRInputAction action : this.inputActions.values()) {
            if (action.isHanded()) {
                for (ControllerType controller : CONTROLLERS) {
                    action.setCurrentHand(controller);
                    if (action.isActive()) {
                        activeStates++;
                    }
                    if (action.isButtonPressed()) {
                        pressedStates++;
                    }
                    if (action.isButtonChanged()) {
                        changedStates++;
                    }
                    this.processInputAction(action);
                }
            } else {
                if (action.isActive()) {
                    activeStates++;
                }
                if (action.isButtonPressed()) {
                    pressedStates++;
                }
                if (action.isButtonChanged()) {
                    changedStates++;
                }
                this.processInputAction(action);
            }
        }

        this.processScrollInput(GuiHandler.KEY_SCROLL_AXIS,
            () -> InputSimulator.scrollMouse(0.0D, 1.0D),
            () -> InputSimulator.scrollMouse(0.0D, -1.0D));
        if (!this.nativeContainerWorldAxesSuppressed) {
            this.processScrollInput(VivecraftVRMod.INSTANCE.keyHotbarScroll,
                () -> this.changeHotbar(-1),
                () -> this.changeHotbar(1));
            this.processSwipeInput(VivecraftVRMod.INSTANCE.keyHotbarSwipeX,
                () -> this.changeHotbar(1),
                () -> this.changeHotbar(-1), null, null);
            this.processSwipeInput(VivecraftVRMod.INSTANCE.keyHotbarSwipeY, null, null,
                () -> this.changeHotbar(-1),
                () -> this.changeHotbar(1));
        }

        if (shouldLogTrackingFrame(frame)) {
            VRSettings.LOGGER.info(
                "Vivecraft: OpenXR input frame {} actions={} activeStates={} pressedStates={} changedStates={}",
                frame, this.inputActions.size(), activeStates, pressedStates, changedStates);
        }
        this.ignorePressesNextFrame = false;
    }

    private void processInputAction(VRInputAction action) {
        if (action.isButtonChanged() && this.inputChangeLogCount < 128) {
            this.inputChangeLogCount++;
            VRSettings.LOGGER.info(
                "Vivecraft: OpenXR input change action={} hand={} type={} active={} pressed={} origin={}",
                action.name,
                action.isHanded() ? action.getCurrentHand() : "none",
                action.type,
                action.isActive(),
                action.isButtonPressed(),
                pathString(action.getLastOrigin()));
        }

        if (this.suppressStaleWorldPress(action)) {
            return;
        }

        if (action.isActive() && action.isEnabledRaw() &&
            (!ClientDataHolderVR.getInstance().vrSettings.ingameBindingsInGui ||
                !(action.actionSet == VRInputActionSet.INGAME &&
                    action.keyBinding.key == InputConstants.Type.MOUSE.getOrCreate(0) &&
                    this.mc.gui.screen() != null)))
        {
            if (action.isButtonChanged()) {
                if (action.isButtonPressed() && action.isEnabled()) {
                    if (!this.ignorePressesNextFrame || canActionBeRepressed(action)) {
                        pressAction(action);
                    }
                } else {
                    unpressAction(action);
                }
            } else if (action.isButtonPressed() && action.isEnabled() && !action.keyBinding.isDown() &&
                canActionBeRepressed(action))
            {
                pressAction(action);
            }
        } else if (checkIfNotMovement(action)) {
            unpressAction(action);
        }
    }

    private boolean canActionBeRepressed(VRInputAction action) {
        return action.actionSet == VRInputActionSet.INGAME &&
            this.unpressedSetKeys.get(action.actionSet).contains(action);
    }

    private void requireFreshWorldPresses() {
        this.nativeContainerFreshPressLatch.clear();
        this.unpressedSetKeys.get(VRInputActionSet.INGAME).clear();
        this.unpressedSetKeys.get(VRInputActionSet.CONTEXTUAL).clear();

        for (VRInputAction action : this.inputActions.values()) {
            if (isWorldActionSet(action.actionSet)) {
                this.nativeContainerFreshPressLatch.arm(
                    action, action.isHanded() ? ALL_HANDED_INPUT_SLOTS : UNHANDED_INPUT_SLOT);
                action.unpressBindingImmediately();
            }
        }
    }

    private boolean suppressStaleWorldPress(VRInputAction action) {
        if (!isWorldActionSet(action.actionSet)) {
            return false;
        }

        int slot = action.isHanded() ? 1 << action.getCurrentHand().ordinal() : UNHANDED_INPUT_SLOT;
        boolean suppress = this.nativeContainerFreshPressLatch.suppressUntilReleased(
            action, slot, action.isActive(), action.isButtonPressed());
        if (suppress) {
            // Reject both the raw state and OpenXR's legacy repress marker.
            // Only a later active-neutral sample may disarm this action slot.
            this.unpressedSetKeys.get(action.actionSet).remove(action);
            if (action.isHanded()) {
                action.unpressBindingImmediately(action.getCurrentHand());
            } else {
                action.unpressBindingImmediately();
            }
        }
        return suppress;
    }

    private static boolean isWorldActionSet(VRInputActionSet actionSet) {
        return actionSet == VRInputActionSet.INGAME || actionSet == VRInputActionSet.CONTEXTUAL;
    }

    private void pressAction(VRInputAction action) {
        action.pressBinding();
        this.unpressedSetKeys.get(action.actionSet).remove(action);
    }

    private void unpressAction(VRInputAction action) {
        if (!this.activeActionSets.contains(action.actionSet) && action.isButtonChanged()) {
            this.unpressedSetKeys.get(action.actionSet).add(action);
        }
        action.unpressBinding();
    }

    private boolean checkIfNotMovement(VRInputAction action) {
        return action.keyBinding != this.mc.options.keyLeft &&
            action.keyBinding != this.mc.options.keyRight &&
            action.keyBinding != this.mc.options.keyUp &&
            action.keyBinding != this.mc.options.keyDown || !this.isMovement;
    }

    private void processScrollInput(KeyMapping keyMapping, Runnable upCallback, Runnable downCallback) {
        VRInputAction action = this.getInputAction(keyMapping);
        if (action.isEnabled() && action.getLastOrigin() != 0L) {
            float value = action.getAxis2D(false).y();
            if (value > 0.0F) {
                upCallback.run();
            } else if (value < 0.0F) {
                downCallback.run();
            }
        }
    }

    private void processSwipeInput(
        KeyMapping keyMapping, Runnable leftCallback, Runnable rightCallback, Runnable upCallback,
        Runnable downCallback)
    {
        VRInputAction action = this.getInputAction(keyMapping);
        if (action.isEnabled() && action.getLastOrigin() != 0L) {
            ControllerType controller = this.findActiveBindingControllerType(keyMapping);
            if (controller != null) {
                TrackpadSwipeSampler sampler = this.trackpadSwipeSamplers.computeIfAbsent(
                    keyMapping.getName(), ignored -> new TrackpadSwipeSampler());
                sampler.update(controller, action.getAxis2D(false));

                if (sampler.isSwipedUp() && upCallback != null) {
                    this.triggerHapticPulse(controller, 0.001F, 400.0F, 0.5F);
                    upCallback.run();
                }
                if (sampler.isSwipedDown() && downCallback != null) {
                    this.triggerHapticPulse(controller, 0.001F, 400.0F, 0.5F);
                    downCallback.run();
                }
                if (sampler.isSwipedLeft() && leftCallback != null) {
                    this.triggerHapticPulse(controller, 0.001F, 400.0F, 0.5F);
                    leftCallback.run();
                }
                if (sampler.isSwipedRight() && rightCallback != null) {
                    this.triggerHapticPulse(controller, 0.001F, 400.0F, 0.5F);
                    rightCallback.run();
                }
            }
        }
    }

    @Override
    public void destroy() {
        try {
            // No haptic callback may retain or race the handles destroyed below.
            this.hapticScheduler.shutdownNow();

            int error;
            // Not sure if we need the action sets one here, as we are shutting down
            for (XrActionSet inputActionSet : this.actionSets.values()) {
                error = XR10.xrDestroyActionSet(inputActionSet);
                logError(error, "xrDestroyActionSet", "");
            }
            if (this.swapchain != null) {
                for (XrSwapchain xrSwapchain : this.swapchain) {
                    if (xrSwapchain != null) {
                        error = XR10.xrDestroySwapchain(xrSwapchain);
                        logError(error, "xrDestroySwapchain", "");
                    }
                }
            }
            if (this.viewBuffer != null) {
                this.viewBuffer.close();
            }
            if (this.xrAppSpace != null) {
                error = XR10.xrDestroySpace(this.xrAppSpace);
                logError(error, "xrDestroySpace", "xrAppSpace");
            }
            if (this.xrViewSpace != null) {
                error = XR10.xrDestroySpace(this.xrViewSpace);
                logError(error, "xrDestroySpace", "xrViewSpace");
            }
            if (this.session != null) {
                error = XR10.xrDestroySession(this.session);
                logError(error, "xrDestroySession", "");
            }
            if (this.instance != null) {
                error = XR10.xrDestroyInstance(this.instance);
                logError(error, "xrDestroyInstance", "");
            }

            if (GraphicsHelper.INSTANCE instanceof OpenGLHelper) {
                GL11.glEnable(GL_FRAMEBUFFER_SRGB);
            }
            this.inputPollingBuffers.close();
            this.inputActionHandles.clear();
            this.actionSets.clear();
            this.eventDataBuffer.close();
        } finally {
            super.destroy();
        }
    }

    @Override
    protected ControllerType findActiveBindingControllerType(KeyMapping keyMapping) {
        if (!this.inputInitialized) {
            return null;
        }
        return getOriginControllerType(this.getInputAction(keyMapping).getLastOrigin());
    }

    @Override
    public void poll(long frameIndex) {
        if (this.initialized) {
            Profiler.get().push("events");
            this.pollVREvents();
            Profiler.get().pop();
            Profiler.get().popPush("updatePose/Vsync");
            this.updatePose();
            Profiler.get().popPush("processInputs");
            this.processInputs();
            Profiler.get().popPush("hmdSampling");
            this.hmdSampling();
            Profiler.get().pop();
        }
    }

    private void updatePose() {
        if (this.mc == null || !this.sessionRunning) {
            this.invalidateControllerPoseValidity();
            return;
        }

        this.invalidateControllerPoseValidity();
        this.refreshHandMapping(this.dh.vrSettings.reverseHands);

        try (MemoryStack stack = MemoryStack.stackPush()) {
            XrFrameState frameState = XrFrameState.calloc(stack).type(XR10.XR_TYPE_FRAME_STATE);

            int error = XR10.xrWaitFrame(
                this.session,
                XrFrameWaitInfo.calloc(stack).type(XR10.XR_TYPE_FRAME_WAIT_INFO),
                frameState);
            logError(error, "xrWaitFrame", "");
            if (error < XR10.XR_SUCCESS) {
                this.frameBegun = false;
                this.headIsTracking = false;
                this.controllerTracking[RIGHT_CONTROLLER] = false;
                this.controllerTracking[LEFT_CONTROLLER] = false;
                if (error == XR10.XR_ERROR_SESSION_NOT_RUNNING) {
                    this.sessionRunning = false;
                    this.isActive = false;
                }
                return;
            }

            this.time = frameState.predictedDisplayTime();
            this.shouldRender = frameState.shouldRender();

            error = XR10.xrBeginFrame(
                this.session,
                XrFrameBeginInfo.calloc(stack).type(XR10.XR_TYPE_FRAME_BEGIN_INFO));
            logError(error, "xrBeginFrame", "");
            this.frameBegun = error >= XR10.XR_SUCCESS;
            if (!this.frameBegun) {
                this.headIsTracking = false;
                this.controllerTracking[RIGHT_CONTROLLER] = false;
                this.controllerTracking[LEFT_CONTROLLER] = false;
                return;
            }

            XrViewState viewState = XrViewState.calloc(stack).type(XR10.XR_TYPE_VIEW_STATE);
            IntBuffer intBuf = stack.callocInt(1);

            XrViewLocateInfo viewLocateInfo = XrViewLocateInfo.calloc(stack);
            viewLocateInfo.set(XR10.XR_TYPE_VIEW_LOCATE_INFO,
                0,
                XR10.XR_VIEW_CONFIGURATION_TYPE_PRIMARY_STEREO,
                frameState.predictedDisplayTime(),
                this.xrAppSpace
            );

            error = XR10.xrLocateViews(this.session, viewLocateInfo, viewState, intBuf, this.viewBuffer);
            logError(error, "xrLocateViews", "");
            if (error < XR10.XR_SUCCESS) {
                this.headIsTracking = false;
                this.controllerTracking[RIGHT_CONTROLLER] = false;
                this.controllerTracking[LEFT_CONTROLLER] = false;
                return;
            }

            this.trackingFrameCount++;

            XrSpaceLocation space_location = XrSpaceLocation.calloc(stack).type(XR10.XR_TYPE_SPACE_LOCATION);

            // HMD pose
            error = XR10.xrLocateSpace(this.xrViewSpace, this.xrAppSpace, this.time, space_location);
            logError(error, "xrLocateSpace", "xrViewSpace");
            long hmdLocationFlags = space_location.locationFlags();
            long validPoseFlags = 3L;
            if (error >= XR10.XR_SUCCESS &&
                (hmdLocationFlags & validPoseFlags) == validPoseFlags)
            {
                OpenXRUtil.openXRPoseToMarix(space_location.pose(), this.hmdPose);
                this.headIsTracking = true;
            } else {
                this.headIsTracking = false;
            }

            long viewStateFlags = viewState.viewStateFlags();
            if ((viewStateFlags & validPoseFlags) == validPoseFlags && intBuf.get(0) >= 2) {
                updateHeadAndEyePosesFromViews();
                this.headIsTracking = true;
            }

            long rightAimFlags = 0L;
            long leftAimFlags = 0L;
            String rightAimPose = "unavailable";
            String leftAimPose = "unavailable";

            if (this.inputInitialized) {
                Profiler.get().push("updateActionState");

                if (this.updateActiveActionSets()) {
                    XrActionsSyncInfo syncInfo = XrActionsSyncInfo.calloc(stack)
                        .type(XR10.XR_TYPE_ACTIONS_SYNC_INFO)
                        .activeActionSets(this.activeActionSetsBuffer);
                    error = XR10.xrSyncActions(this.session, syncInfo);
                    logError(error, "xrSyncActions", "");
                }

                this.inputActions.values().forEach(this::readNewData);

                for (int logical = 0; logical < CONTROLLERS.length; logical++) {
                    int physical = OpenXRHandedness.physicalIndex(logical, this.reverseHandsForFrame);
                    ControllerType logicalController = CONTROLLERS[logical];
                    this.gripActionActive[logical] = this.readPoseData(
                        this.gripActions[physical], logicalController);
                    this.aimActionActive[logical] = this.readPoseData(
                        this.aimActions[physical], logicalController);
                }

                Profiler.get().pop();

                // Action spaces are immutable physical-hand objects. Locate a
                // physical space and copy it into the matching logical slot.
                for (int logical = 0; logical < CONTROLLERS.length; logical++) {
                    int physical = OpenXRHandedness.physicalIndex(logical, this.reverseHandsForFrame);

                    error = XR10.xrLocateSpace(
                        this.gripSpace[physical], this.xrAppSpace, this.time, space_location);
                    logError(error, "xrLocateSpace", GRIP_SPACE_LABELS[physical]);
                    this.gripLocationFlags[logical] = space_location.locationFlags();
                    if (this.gripActionActive[logical] && error >= XR10.XR_SUCCESS &&
                        (this.gripLocationFlags[logical] & validPoseFlags) == validPoseFlags)
                    {
                        OpenXRUtil.openXRPoseToMarix(space_location.pose(), this.rawGripPose[logical]);
                        this.handRotation[logical].set(this.rawGripPose[logical]);
                        this.gripPoseValid[logical] = true;
                        this.gripPoseFrame[logical] = this.trackingFrameCount;
                        this.gripPoseTime[logical] = this.time;
                    }

                    error = XR10.xrLocateSpace(
                        this.aimSpace[physical], this.xrAppSpace, this.time, space_location);
                    logError(error, "xrLocateSpace", AIM_SPACE_LABELS[physical]);
                    this.aimLocationFlags[logical] = space_location.locationFlags();
                    if (logical == RIGHT_CONTROLLER) {
                        rightAimFlags = this.aimLocationFlags[logical];
                        rightAimPose = poseString(space_location.pose());
                    } else {
                        leftAimFlags = this.aimLocationFlags[logical];
                        leftAimPose = poseString(space_location.pose());
                    }
                    if (this.aimActionActive[logical] && error >= XR10.XR_SUCCESS &&
                        (this.aimLocationFlags[logical] & validPoseFlags) == validPoseFlags)
                    {
                        OpenXRUtil.openXRPoseToMarix(space_location.pose(), this.rawAimPose[logical]);
                        this.controllerPose[logical].set(this.rawAimPose[logical]);
                        this.controllerRotation[logical].set(this.rawAimPose[logical]);
                        this.aimPoseValid[logical] = true;
                        this.aimPoseFrame[logical] = this.trackingFrameCount;
                        this.aimPoseTime[logical] = this.time;
                    }

                    this.controllerTracking[logical] =
                        this.aimPoseValid[logical] && this.gripPoseValid[logical];
                    if (this.controllerTracking[logical]) {
                        OpenXRPoseMath.aimToGrip(
                            this.rawAimPose[logical],
                            this.rawGripPose[logical],
                            this.inverseAimScratch[logical],
                            this.aimToGripTransform[logical]);
                    }
                }
            }

            if (shouldLogTrackingFrame(this.trackingFrameCount)) {
                VRSettings.LOGGER.info(
                    "Vivecraft: OpenXR tracking frame {} state={} predictedTime={} shouldRender={} " +
                        "viewFlags=0x{} viewCount={} hmdFlags=0x{} hmd={} rightActive={} rightFlags=0x{} " +
                        "right={} leftActive={} leftFlags=0x{} left={}",
                    this.trackingFrameCount,
                    sessionStateName(this.sessionState),
                    this.time,
                    this.shouldRender,
                    Long.toHexString(viewStateFlags),
                    intBuf.get(0),
                    Long.toHexString(hmdLocationFlags),
                    matrixPoseString(this.hmdPose),
                    this.aimActionActive[RIGHT_CONTROLLER],
                    Long.toHexString(rightAimFlags),
                    rightAimPose,
                    this.aimActionActive[LEFT_CONTROLLER],
                    Long.toHexString(leftAimFlags),
                    leftAimPose);
            }

            if (this.controllerTracking[RIGHT_CONTROLLER]) {
                Matrix4fc tip = this.controllerRotation[RIGHT_CONTROLLER];
                Matrix4fc hand = this.handRotation[RIGHT_CONTROLLER];

                Vector3f tipVec = tip.transformDirection(MathUtils.BACK, this.controllerTipDirection);
                Vector3f handVec = hand.transformDirection(MathUtils.BACK, this.controllerHandDirection);

                float dot = Math.abs(tipVec.dot(handVec));

                float angleRad = (float) Math.acos(dot);
                float angleDeg = Mth.RAD_TO_DEG * angleRad;

                this.gunStyle = angleDeg > 10.0F;
                this.gunAngle = angleDeg;
            }

            this.updateAim();
        }
    }

    public void readNewData(VRInputAction action) {
        switch (action.type) {
            case "boolean" -> {
                if (action.isHanded()) {
                    for (ControllerType controllertype1 : CONTROLLERS) {
                        this.readBoolean(action, controllertype1);
                    }
                } else {
                    this.readBoolean(action, null);
                }
            }

            case "vector1" -> {
                if (action.isHanded()) {
                    for (ControllerType controllertype : CONTROLLERS) {
                        this.readFloat(action, controllertype);
                    }
                } else {
                    this.readFloat(action, null);
                }
            }

            case "vector2" -> {
                if (action.isHanded()) {
                    for (ControllerType controllertype : CONTROLLERS) {
                        this.readVecData(action, controllertype);
                    }
                } else {
                    this.readVecData(action, null);
                }
            }
        }
    }

    private void readBoolean(VRInputAction action, ControllerType hand) {
        int i = 0;

        if (hand != null) {
            i = hand.ordinal();
        }
        XrActionStateGetInfo info = this.inputPollingBuffers.prepare(
            this.getInputActionHandle(action), getSubactionPath(hand));
        XrActionStateBoolean state = this.inputPollingBuffers.booleanState();
        int error = XR10.xrGetActionStateBoolean(this.session, info, state);
        logError(error, "xrGetActionStateBoolean", action.name);
        if (error < XR10.XR_SUCCESS) {
            action.digitalData[i].state = false;
            action.digitalData[i].isActive = false;
            action.digitalData[i].isChanged = false;
            action.digitalData[i].activeOrigin = 0L;
            return;
        }

        action.digitalData[i].state = state.currentState();
        action.digitalData[i].isActive = state.isActive();
        action.digitalData[i].isChanged = state.changedSinceLastSync();
        action.digitalData[i].activeOrigin = resolveActionOrigin(action, hand, state.isActive());
    }

    private void readFloat(VRInputAction action, ControllerType hand) {
        int i = 0;

        if (hand != null) {
            i = hand.ordinal();
        }
        XrActionStateGetInfo info = this.inputPollingBuffers.prepare(
            this.getInputActionHandle(action), getSubactionPath(hand));
        XrActionStateFloat state = this.inputPollingBuffers.floatState();
        int error = XR10.xrGetActionStateFloat(this.session, info, state);
        logError(error, "xrGetActionStateFloat", action.name);
        if (error < XR10.XR_SUCCESS) {
            action.analogData[i].deltaX = -action.analogData[i].x;
            action.analogData[i].x = 0.0F;
            action.analogData[i].activeOrigin = 0L;
            action.analogData[i].isActive = false;
            action.analogData[i].isChanged = false;
            return;
        }

        action.analogData[i].deltaX = state.currentState() - action.analogData[i].x;
        action.analogData[i].x = state.currentState();
        action.analogData[i].activeOrigin = resolveActionOrigin(action, hand, state.isActive());
        action.analogData[i].isActive = state.isActive();
        action.analogData[i].isChanged = state.changedSinceLastSync();
    }

    private void readVecData(VRInputAction action, ControllerType hand) {
        int i = 0;

        if (hand != null) {
            i = hand.ordinal();
        }
        XrActionStateGetInfo info = this.inputPollingBuffers.prepare(
            this.getInputActionHandle(action), getSubactionPath(hand));
        XrActionStateVector2f state = this.inputPollingBuffers.vector2State();
        int error = XR10.xrGetActionStateVector2f(this.session, info, state);
        logError(error, "xrGetActionStateVector2f", action.name);
        if (error < XR10.XR_SUCCESS) {
            action.analogData[i].deltaX = -action.analogData[i].x;
            action.analogData[i].deltaY = -action.analogData[i].y;
            action.analogData[i].x = 0.0F;
            action.analogData[i].y = 0.0F;
            action.analogData[i].activeOrigin = 0L;
            action.analogData[i].isActive = false;
            action.analogData[i].isChanged = false;
            return;
        }

        XrVector2f currentState = this.inputPollingBuffers.vector2Value();
        action.analogData[i].deltaX = currentState.x() - action.analogData[i].x;
        action.analogData[i].deltaY = currentState.y() - action.analogData[i].y;
        action.analogData[i].x = currentState.x();
        action.analogData[i].y = currentState.y();
        action.analogData[i].activeOrigin = resolveActionOrigin(action, hand, state.isActive());
        action.analogData[i].isActive = state.isActive();
        action.analogData[i].isChanged = state.changedSinceLastSync();
    }

    private boolean readPoseData(XrAction action, ControllerType hand) {
        XrActionStateGetInfo info = this.inputPollingBuffers.prepare(action, getSubactionPath(hand));
        XrActionStatePose state = this.inputPollingBuffers.poseState();
        int error = XR10.xrGetActionStatePose(this.session, info, state);
        logError(error, "xrGetActionStatePose", "");
        return error >= XR10.XR_SUCCESS && state.isActive();
    }

    private void invalidateControllerPoseValidity() {
        for (int logical = 0; logical < CONTROLLERS.length; logical++) {
            this.controllerTracking[logical] = false;
            this.gripActionActive[logical] = false;
            this.aimActionActive[logical] = false;
            this.gripPoseValid[logical] = false;
            this.aimPoseValid[logical] = false;
            this.gripPoseFrame[logical] = -1L;
            this.aimPoseFrame[logical] = -1L;
            this.gripPoseTime[logical] = 0L;
            this.aimPoseTime[logical] = 0L;
            this.gripLocationFlags[logical] = 0L;
            this.aimLocationFlags[logical] = 0L;
        }
    }

    private void refreshHandMapping(boolean reverseHands) {
        if (this.reverseHandsForFrame != reverseHands) {
            this.reverseHandsForFrame = reverseHands;
            // Cached action origins are indexed by logical hand. Discard them
            // when the logical-to-physical mapping changes.
            this.actionOrigins.clear();
            this.trackpadSwipeSamplers.clear();
            this.ignorePressesNextFrame = true;
        }
    }

    private long resolveActionOrigin(VRInputAction action, ControllerType hand, boolean active) {
        if (!active) {
            return 0L;
        }

        int index = hand == null ? CONTROLLERS.length : hand.ordinal();
        long[] cachedOrigins = this.actionOrigins.computeIfAbsent(
            action.handle, ignored -> new long[CONTROLLERS.length + 1]);
        if (cachedOrigins[index] != 0L) {
            return cachedOrigins[index];
        }

        for (long origin : getOrigins(action)) {
            if (origin != 0L && (hand == null || getOriginControllerType(origin) == hand)) {
                cachedOrigins[index] = origin;
                return origin;
            }
        }

        if (hand != null) {
            cachedOrigins[index] = getSubactionPath(hand);
        }
        return cachedOrigins[index];
    }

    private void updateHeadAndEyePosesFromViews() {
        XrPosef leftPose = this.viewBuffer.get(0).pose();
        XrPosef rightPose = this.viewBuffer.get(1).pose();
        XrQuaternionf orientation = leftPose.orientation();
        this.hmdPose
            .set(new Quaternionf(orientation.x(), orientation.y(), orientation.z(), orientation.w()))
            .setTranslation(
                (leftPose.position$().x() + rightPose.position$().x()) * 0.5F,
                (leftPose.position$().y() + rightPose.position$().y()) * 0.5F,
                (leftPose.position$().z() + rightPose.position$().z()) * 0.5F)
            .m33(1.0F);

        this.inverseHeadPose.set(this.hmdPose).invert();
        OpenXRUtil.openXRPoseToMarix(leftPose, this.absoluteEyePose);
        this.inverseHeadPose.mul(this.absoluteEyePose, this.hmdPoseLeftEye);
        OpenXRUtil.openXRPoseToMarix(rightPose, this.absoluteEyePose);
        this.inverseHeadPose.mul(this.absoluteEyePose, this.hmdPoseRightEye);
    }

    private static boolean shouldLogTrackingFrame(long frame) {
        return frame <= 5 || frame == 30 || frame == 120 || frame % 600 == 0;
    }

    private static String poseString(XrPosef pose) {
        return String.format(Locale.ROOT,
            "p=(%.3f,%.3f,%.3f) q=(%.3f,%.3f,%.3f,%.3f)",
            pose.position$().x(), pose.position$().y(), pose.position$().z(),
            pose.orientation().x(), pose.orientation().y(), pose.orientation().z(), pose.orientation().w());
    }

    private static String matrixPoseString(Matrix4fc pose) {
        Vector3f position = pose.getTranslation(new Vector3f());
        Vector3f forward = pose.transformDirection(MathUtils.BACK, new Vector3f());
        return String.format(Locale.ROOT,
            "p=(%.3f,%.3f,%.3f) forward=(%.3f,%.3f,%.3f)",
            position.x, position.y, position.z, forward.x, forward.y, forward.z);
    }

    private long getSubactionPath(ControllerType hand) {
        if (hand == null) {
            return 0L;
        }
        int physical = OpenXRHandedness.physicalIndex(hand.ordinal(), this.reverseHandsForFrame);
        return getPath(physical == RIGHT_CONTROLLER ?
            VR.k_pchPathUserHandRight : VR.k_pchPathUserHandLeft);
    }

    private void logCurrentInteractionProfiles() {
        if (this.session == null) {
            return;
        }

        try (MemoryStack stack = MemoryStack.stackPush()) {
            for (String hand : BOTH_HANDS) {
                XrInteractionProfileState profileState = XrInteractionProfileState.calloc(stack)
                    .type(XR10.XR_TYPE_INTERACTION_PROFILE_STATE);
                int error = XR10.xrGetCurrentInteractionProfile(this.session, getPath(hand), profileState);
                if (error >= XR10.XR_SUCCESS) {
                    VRSettings.LOGGER.info("Vivecraft: OpenXR interaction profile {} = {}",
                        hand, pathString(profileState.interactionProfile()));
                } else {
                    logError(error, "xrGetCurrentInteractionProfile", hand);
                }
            }
        }
    }

    private String pathString(long path) {
        if (path == 0L) {
            return "none";
        }

        try (MemoryStack stack = MemoryStack.stackPush()) {
            IntBuffer count = stack.callocInt(1);
            int error = XR10.xrPathToString(this.instance, path, count, null);
            if (error < XR10.XR_SUCCESS || count.get(0) <= 1) {
                return "unresolved(" + path + ")";
            }

            ByteBuffer value = stack.calloc(count.get(0));
            error = XR10.xrPathToString(this.instance, path, count, value);
            return error >= XR10.XR_SUCCESS ? MemoryUtil.memUTF8(value) : "unresolved(" + path + ")";
        }
    }

    private boolean updateActiveActionSets() {
        ArrayList<VRInputActionSet> arraylist = this.pendingActionSets;
        arraylist.clear();
        arraylist.add(VRInputActionSet.GLOBAL);

        // we are always modded
        arraylist.add(VRInputActionSet.MOD);

        arraylist.add(VRInputActionSet.MIXED_REALITY);
        arraylist.add(VRInputActionSet.TECHNICAL);

        if (this.mc.gui.screen() == null) {
            arraylist.add(VRInputActionSet.INGAME);
            arraylist.add(VRInputActionSet.CONTEXTUAL);
        } else {
            arraylist.add(VRInputActionSet.GUI);
            if (ClientDataHolderVR.getInstance().vrSettings.ingameBindingsInGui &&
                !this.isNativeContainerLocomotionActive())
            {
                arraylist.add(VRInputActionSet.INGAME);
            }
        }

        if (KeyboardHandler.SHOWING || RadialHandler.isShowing()) {
            arraylist.add(VRInputActionSet.KEYBOARD);
        }

        if (this.activeActionSetsBuffer == null) {
            this.activeActionSetsBuffer = XrActiveActionSet.calloc(arraylist.size());
        } else if (this.activeActionSetsBuffer.capacity() != arraylist.size()) {
            this.activeActionSetsBuffer.close();
            this.activeActionSetsBuffer = XrActiveActionSet.calloc(arraylist.size());
        }

        for (int i = 0; i < arraylist.size(); ++i) {
            VRInputActionSet vrinputactionset = arraylist.get(i);
            this.activeActionSetsBuffer.get(i)
                .set(this.getActionSet(vrinputactionset), NULL);
        }

        for (VRInputActionSet set : this.activeActionSets) {
            if (!arraylist.contains(set)) {
                this.unpressedSetKeys.get(set).clear();
            }
        }
        ArrayList<VRInputActionSet> previousActionSets = this.activeActionSets;
        this.activeActionSets = arraylist;
        this.pendingActionSets = previousActionSets;

        return !arraylist.isEmpty();
    }

    private XrActionSet getActionSet(VRInputActionSet actionSet) {
        return Objects.requireNonNull(this.actionSets.get(actionSet), "OpenXR action set is not initialized");
    }

    private XrAction getInputActionHandle(VRInputAction action) {
        return Objects.requireNonNull(
            this.inputActionHandles.get(action), "OpenXR input action is not initialized: " + action.name);
    }

    @Override
    protected boolean supportsNativeContainerLocomotion() {
        return true;
    }

    @Override
    protected boolean suppressNativeContainerWorldAxes() {
        return this.nativeContainerWorldAxesSuppressed;
    }

    private boolean areContainerWorldAxesNeutral() {
        return this.isAxisNeutral(VivecraftVRMod.INSTANCE.keyFreeMoveRotate)
            && this.isAxisNeutral(VivecraftVRMod.INSTANCE.keyRotateAxis)
            && this.isAxisNeutral(VivecraftVRMod.INSTANCE.keyRotateLeft)
            && this.isAxisNeutral(VivecraftVRMod.INSTANCE.keyRotateRight)
            && this.isAxisNeutral(VivecraftVRMod.INSTANCE.keyFlickStick)
            && this.isAxisNeutral(VivecraftVRMod.INSTANCE.keyHotbarScroll)
            && this.isAxisNeutral(VivecraftVRMod.INSTANCE.keyHotbarSwipeX)
            && this.isAxisNeutral(VivecraftVRMod.INSTANCE.keyHotbarSwipeY);
    }

    private boolean isAxisNeutral(KeyMapping keyMapping) {
        VRInputAction action = this.getInputAction(keyMapping);
        if (action == null) {
            return true;
        }
        for (VRInputAction.AnalogData data : action.analogData) {
            if (Math.abs(data.x) > 0.15F || Math.abs(data.y) > 0.15F || Math.abs(data.z) > 0.15F) {
                return false;
            }
        }
        return true;
    }

    XrAction getHapticAction(int controller) {
        return Objects.requireNonNull(
            this.hapticActions[controller], "OpenXR haptic action is not initialized");
    }

    private void pollVREvents() {
        while (true) {
            this.eventDataBuffer.clear();
            this.eventDataBuffer.type(XR10.XR_TYPE_EVENT_DATA_BUFFER);
            int error = XR10.xrPollEvent(this.instance, this.eventDataBuffer);
            logError(error, "xrPollEvent", "");
            if (error != XR10.XR_SUCCESS) {
                break;
            }
            XrEventDataBaseHeader event = XrEventDataBaseHeader.create(this.eventDataBuffer.address());

            switch (event.type()) {
                case XR10.XR_TYPE_EVENT_DATA_INSTANCE_LOSS_PENDING -> {
                    XrEventDataInstanceLossPending instanceLossPending = XrEventDataInstanceLossPending.create(
                        event.address());
                }
                case XR10.XR_TYPE_EVENT_DATA_SESSION_STATE_CHANGED -> {
                    this.sessionChanged(XrEventDataSessionStateChanged.create(event.address()));
                }
                case XR10.XR_TYPE_EVENT_DATA_INTERACTION_PROFILE_CHANGED -> {
                    this.actionOrigins.clear();
                    this.originControllerTypes.clear();
                    logCurrentInteractionProfiles();
                }
                case XR10.XR_TYPE_EVENT_DATA_REFERENCE_SPACE_CHANGE_PENDING -> {
                }
                default -> {
                }
            }
        }
    }

    private void sessionChanged(XrEventDataSessionStateChanged xrEventDataSessionStateChanged) {
        int state = xrEventDataSessionStateChanged.state();
        this.sessionState = state;
        this.backgroundPolicy.onSessionState(backgroundSessionState(state));
        VRSettings.LOGGER.info("Vivecraft: OpenXR session state changed to {}", sessionStateName(state));

        switch (state) {
            case XR10.XR_SESSION_STATE_READY: {
                try (MemoryStack stack = MemoryStack.stackPush()) {
                    XrSessionBeginInfo sessionBeginInfo = XrSessionBeginInfo.calloc(stack);
                    sessionBeginInfo.type(XR10.XR_TYPE_SESSION_BEGIN_INFO);
                    sessionBeginInfo.next(NULL);
                    sessionBeginInfo.primaryViewConfigurationType(XR10.XR_VIEW_CONFIGURATION_TYPE_PRIMARY_STEREO);

                    int error = XR10.xrBeginSession(this.session, sessionBeginInfo);
                    logError(error, "xrBeginSession", "XR_SESSION_STATE_READY");
                    if (error < XR10.XR_SUCCESS) {
                        this.sessionRunning = false;
                        this.isActive = false;
                        throw new IllegalStateException("xrBeginSession failed with " + getResultName(error));
                    }
                }
                this.sessionRunning = true;
                this.isActive = true;
                break;
            }
            case XR10.XR_SESSION_STATE_STOPPING: {
                this.isActive = false;
                this.sessionRunning = false;
                int error = XR10.xrEndSession(this.session);
                logError(error, "xrEndSession", "XR_SESSION_STATE_STOPPING");
                break;
            }
            case XR10.XR_SESSION_STATE_SYNCHRONIZED: {
                this.isActive = true;
                break;
            }
            case XR10.XR_SESSION_STATE_VISIBLE: {
                this.isActive = true;
                break;
            }
            case XR10.XR_SESSION_STATE_FOCUSED: {
                this.isActive = true;
                logCurrentInteractionProfiles();
                break;
            }
            case XR10.XR_SESSION_STATE_EXITING: {
                this.sessionRunning = false;
                this.isActive = false;
                if (ClientDataHolderVR.getInstance().vrSettings.closeWithRuntime) {
                    VRSettings.LOGGER.info("Vivecraft: OpenXR stopped, closing the game with it");
                    this.mc.stop();
                } else {
                    VRSettings.LOGGER.info("Vivecraft: OpenXR stopped, disabling VR");
                    VRState.VR_ENABLED = !VRState.VR_ENABLED;
                    ClientDataHolderVR.getInstance().vrSettings.vrEnabled = VRState.VR_ENABLED;
                    ClientDataHolderVR.getInstance().vrSettings.saveOptions();
                }
                break;
            }
            case XR10.XR_SESSION_STATE_IDLE: {
                this.isActive = false;
                this.sessionRunning = false;
                break;
            }
            case XR10.XR_SESSION_STATE_LOSS_PENDING: {
                this.sessionRunning = false;
                this.isActive = false;
                break;
            }
            default:
                break;
        }
        this.finishStoppedSessionThrottleTransition();
    }

    private static QuestOpenXRBackgroundPolicy.SessionState backgroundSessionState(int state) {
        return switch (state) {
            case XR10.XR_SESSION_STATE_IDLE -> QuestOpenXRBackgroundPolicy.SessionState.IDLE;
            case XR10.XR_SESSION_STATE_READY -> QuestOpenXRBackgroundPolicy.SessionState.READY;
            case XR10.XR_SESSION_STATE_SYNCHRONIZED -> QuestOpenXRBackgroundPolicy.SessionState.SYNCHRONIZED;
            case XR10.XR_SESSION_STATE_VISIBLE -> QuestOpenXRBackgroundPolicy.SessionState.VISIBLE;
            case XR10.XR_SESSION_STATE_FOCUSED -> QuestOpenXRBackgroundPolicy.SessionState.FOCUSED;
            case XR10.XR_SESSION_STATE_STOPPING -> QuestOpenXRBackgroundPolicy.SessionState.STOPPING;
            case XR10.XR_SESSION_STATE_LOSS_PENDING -> QuestOpenXRBackgroundPolicy.SessionState.LOSS_PENDING;
            case XR10.XR_SESSION_STATE_EXITING -> QuestOpenXRBackgroundPolicy.SessionState.EXITING;
            default -> QuestOpenXRBackgroundPolicy.SessionState.UNKNOWN;
        };
    }

    @Override
    public Vector2f getPlayAreaSize() {
        try (MemoryStack stack = MemoryStack.stackPush()) {
            XrExtent2Df vec = XrExtent2Df.calloc(stack);
            int error = XR10.xrGetReferenceSpaceBoundsRect(this.session, this.appSpaceType, vec);
            logError(error, "xrGetReferenceSpaceBoundsRect", "");
            return new Vector2f(vec.width(), vec.height());
        }
    }

    @Override
    public void refreshControllerTransforms() {

    }

    @Override
    public boolean init() throws RenderConfigException {
        if (this.initialized) {
            return true;
        } else if (this.tried) {
            return this.initialized;
        } else {
            this.tried = true;
            this.mc = Minecraft.getInstance();
            try {
                this.initializeOpenXRInstance();
                this.initializeOpenXRSession();
                this.initializeOpenXRSpace();
                this.initializeOpenXRSwapChain();
                this.initInputAndApplication();
                VRSettings.LOGGER.info(
                    "Vivecraft: OpenXR runtime policy refreshRateOwner={} performanceHint={}",
                    OpenXRRuntimePolicy.REFRESH_RATE_OWNER,
                    OpenXRRuntimePolicy.PERFORMANCE_HINT);
            } catch (RenderConfigException e) {
                throw e;
            } catch (Exception e) {
                VRSettings.LOGGER.error("Vivecraft: OpenXR init failed", e);
                this.initSuccess = false;
                this.initStatus = e.getLocalizedMessage();
                return false;
            }

            // TODO Seated when no controllers

            VRSettings.LOGGER.info("Vivecraft: OpenXR initialized & VR connected.");
            this.deviceVelocity = new Vector3f[64];

            for (int i = 0; i < this.poseMatrices.length; ++i) {
                this.poseMatrices[i] = new Matrix4f();
                this.deviceVelocity[i] = new Vector3f();
            }

            this.initialized = true;
            return true;
        }
    }

    private void initializeOpenXRInstance() {
        try (MemoryStack stack = MemoryStack.stackPush()) {
            this.device.initOpenXRLoader(stack);

            // Check extensions
            IntBuffer numExtensions = stack.callocInt(1);
            int error = XR10.xrEnumerateInstanceExtensionProperties((ByteBuffer) null, numExtensions, null);
            DeviceCompat.checkResult(error, "xrEnumerateInstanceExtensionProperties(count)");

            XrExtensionProperties.Buffer properties = new XrExtensionProperties.Buffer(
                bufferStack(numExtensions.get(0), XrExtensionProperties.SIZEOF, XR10.XR_TYPE_EXTENSION_PROPERTIES)
            );

            // Load extensions
            error = XR10.xrEnumerateInstanceExtensionProperties((ByteBuffer) null, numExtensions, properties);
            DeviceCompat.checkResult(error, "xrEnumerateInstanceExtensionProperties(list)");

            Set<String> availableExtensions = new HashSet<>();
            while (properties.hasRemaining()) {
                availableExtensions.add(properties.get().extensionNameString());
            }

            LinkedHashSet<String> requestedExtensions = new LinkedHashSet<>();
            for (String requiredExtension : this.device.getRequiredInstanceExtensions()) {
                if (!availableExtensions.contains(requiredExtension)) {
                    throw new RuntimeException("OpenXR runtime is missing required extension " + requiredExtension);
                }
                requestedExtensions.add(requiredExtension);
            }

            for (String optionalExtension : List.of(
                EXTHPMixedRealityController.XR_EXT_HP_MIXED_REALITY_CONTROLLER_EXTENSION_NAME,
                HTCViveCosmosControllerInteraction.XR_HTC_VIVE_COSMOS_CONTROLLER_INTERACTION_EXTENSION_NAME,
                BDControllerInteraction.XR_BD_CONTROLLER_INTERACTION_EXTENSION_NAME))
            {
                if (availableExtensions.contains(optionalExtension)) {
                    requestedExtensions.add(optionalExtension);
                }
            }

            this.enabledInstanceExtensions.clear();
            this.enabledInstanceExtensions.addAll(requestedExtensions);
            PointerBuffer extensions = stack.callocPointer(requestedExtensions.size());
            requestedExtensions.forEach(extension -> extensions.put(memAddress(stackUTF8(extension))));

            // Create APP info
            XrApplicationInfo applicationInfo = XrApplicationInfo.calloc(stack);
            applicationInfo.apiVersion(XR10.XR_MAKE_VERSION(1, 0, 40));
            applicationInfo.applicationName(stack.UTF8("Vivecraft"));
            applicationInfo.applicationVersion(1);

            // Create instance info
            XrInstanceCreateInfo createInfo = XrInstanceCreateInfo.calloc(stack);
            createInfo.type(XR10.XR_TYPE_INSTANCE_CREATE_INFO);
            createInfo.next(this.device.getPlatformInfo(stack));
            createInfo.createFlags(0);
            createInfo.applicationInfo(applicationInfo);
            createInfo.enabledApiLayerNames(null);
            createInfo.enabledExtensionNames(extensions.flip());

            // Create XR instance
            PointerBuffer instancePtr = stack.callocPointer(1);
            int xrResult = XR10.xrCreateInstance(createInfo, instancePtr);
            if (xrResult == XR10.XR_ERROR_RUNTIME_FAILURE) {
                throw new RuntimeException("Failed to create xrInstance, are you sure your headset is plugged in?");
            } else if (xrResult == XR10.XR_ERROR_INSTANCE_LOST) {
                throw new RuntimeException("Failed to create xrInstance due to runtime updating");
            } else if (xrResult < 0) {
                throw new RuntimeException("XR method returned " + xrResult);
            }
            this.instance = new XrInstance(instancePtr.get(0), createInfo);

            this.poseMatrices = new Matrix4f[64];

            for (int i = 0; i < this.poseMatrices.length; ++i) {
                this.poseMatrices[i] = new Matrix4f();
            }

            this.initSuccess = true;
        }
    }

    public static MCOpenXR get() {
        return OME;
    }

    private void initializeOpenXRSession() throws RenderConfigException {
        try (MemoryStack stack = MemoryStack.stackPush()) {
            // Create system
            XrSystemGetInfo system = XrSystemGetInfo.calloc(stack);
            system.type(XR10.XR_TYPE_SYSTEM_GET_INFO);
            system.next(NULL);
            system.formFactor(XR10.XR_FORM_FACTOR_HEAD_MOUNTED_DISPLAY);

            LongBuffer longBuffer = stack.callocLong(1);
            int error = XR10.xrGetSystem(this.instance, system, longBuffer);
            DeviceCompat.checkResult(error, "xrGetSystem");
            this.systemID = longBuffer.get(0);

            if (this.systemID == 0) {
                throw new RuntimeException("No compatible headset detected");
            }

            XrSystemProperties systemProperties = XrSystemProperties.calloc(stack).type(XR10.XR_TYPE_SYSTEM_PROPERTIES);
            error = XR10.xrGetSystemProperties(this.instance, this.systemID, systemProperties);
            DeviceCompat.checkResult(error, "xrGetSystemProperties");
            XrSystemTrackingProperties trackingProperties = systemProperties.trackingProperties();
            XrSystemGraphicsProperties graphicsProperties = systemProperties.graphicsProperties();

            MCOpenXR.get().systemName = memUTF8(memAddress(systemProperties.systemName()));
            this.backgroundPolicy.setSystemName(this.systemName);
            int vendor = systemProperties.vendorId();
            boolean orientationTracking = trackingProperties.orientationTracking();
            boolean positionTracking = trackingProperties.positionTracking();
            int maxWidth = graphicsProperties.maxSwapchainImageWidth();
            int maxHeight = graphicsProperties.maxSwapchainImageHeight();
            int maxLayerCount = graphicsProperties.maxLayerCount();

            VRSettings.LOGGER.info("Found device with id:  {}", this.systemID);
            VRSettings.LOGGER.info("Headset Name: {}, Vendor: {}", MCOpenXR.get().systemName, vendor);
            if (this.backgroundPolicy.isEnabled()) {
                VRSettings.LOGGER.info(
                    "Vivecraft: Lab Quest stopped-session protection enabled (event polling interval={} ms)",
                    QuestOpenXRBackgroundPolicy.STOPPED_SESSION_POLL_INTERVAL_NANOS / 1_000_000L);
            }
            VRSettings.LOGGER.info("Headset Orientation Tracking: {}, Position Tracking: {}", orientationTracking,
                positionTracking);
            VRSettings.LOGGER.info("Headset Max Width: {}, Max Height: {}, Max Layer Count: {}", maxWidth, maxHeight,
                maxLayerCount);

            // Create session
            XrSessionCreateInfo info = XrSessionCreateInfo.calloc(stack);
            info.type(XR10.XR_TYPE_SESSION_CREATE_INFO);
            info.next(this.device.checkGraphics(stack, this.instance, this.systemID).address());
            info.createFlags(0);
            info.systemId(this.systemID);

            PointerBuffer sessionPtr = stack.callocPointer(1);
            error = XR10.xrCreateSession(this.instance, info, sessionPtr);
            DeviceCompat.checkResult(error, "xrCreateSession");

            this.session = new XrSession(sessionPtr.get(0), this.instance);
        }
    }

    private void initializeOpenXRSpace() {
        try (MemoryStack stack = MemoryStack.stackPush()) {
            XrPosef identityPose = XrPosef.calloc(stack);
            identityPose.set(
                XrQuaternionf.calloc(stack).set(0, 0, 0, 1),
                XrVector3f.calloc(stack)
            );

            XrReferenceSpaceCreateInfo referenceSpaceCreateInfo = XrReferenceSpaceCreateInfo.calloc(stack);
            referenceSpaceCreateInfo.type(XR10.XR_TYPE_REFERENCE_SPACE_CREATE_INFO);
            referenceSpaceCreateInfo.next(NULL);
            referenceSpaceCreateInfo.referenceSpaceType(XR10.XR_REFERENCE_SPACE_TYPE_STAGE);
            referenceSpaceCreateInfo.poseInReferenceSpace(identityPose);

            PointerBuffer pp = stack.callocPointer(1);
            int error = XR10.xrCreateReferenceSpace(this.session, referenceSpaceCreateInfo, pp);
            if (error == XR10.XR_ERROR_REFERENCE_SPACE_UNSUPPORTED) {
                this.appSpaceType = XR10.XR_REFERENCE_SPACE_TYPE_LOCAL;
                referenceSpaceCreateInfo.referenceSpaceType(this.appSpaceType);
                pp.put(0, NULL);
                error = XR10.xrCreateReferenceSpace(this.session, referenceSpaceCreateInfo, pp);
            }
            DeviceCompat.checkResult(error, "xrCreateReferenceSpace(STAGE/LOCAL)");
            this.xrAppSpace = new XrSpace(pp.get(0), this.session);

            referenceSpaceCreateInfo.referenceSpaceType(XR10.XR_REFERENCE_SPACE_TYPE_VIEW);
            error = XR10.xrCreateReferenceSpace(this.session, referenceSpaceCreateInfo, pp);
            DeviceCompat.checkResult(error, "xrCreateReferenceSpace(VIEW)");
            this.xrViewSpace = new XrSpace(pp.get(0), this.session);
        }
    }

    private void initializeOpenXRSwapChain() {
        try (MemoryStack stack = stackPush()) {
            // Check amount of views
            IntBuffer intBuf = stack.callocInt(1);
            int error = XR10.xrEnumerateViewConfigurationViews(this.instance, this.systemID,
                XR10.XR_VIEW_CONFIGURATION_TYPE_PRIMARY_STEREO, intBuf, null);
            DeviceCompat.checkResult(error, "xrEnumerateViewConfigurationViews(count)");

            // Get all views
            ByteBuffer viewConfBuffer = bufferStack(intBuf.get(0), XrViewConfigurationView.SIZEOF,
                XR10.XR_TYPE_VIEW_CONFIGURATION_VIEW);
            XrViewConfigurationView.Buffer views = new XrViewConfigurationView.Buffer(viewConfBuffer);
            error = XR10.xrEnumerateViewConfigurationViews(this.instance, this.systemID,
                XR10.XR_VIEW_CONFIGURATION_TYPE_PRIMARY_STEREO, intBuf, views);
            DeviceCompat.checkResult(error, "xrEnumerateViewConfigurationViews(list)");
            int viewCountNumber = intBuf.get(0);
            if (viewCountNumber < 2) {
                throw new IllegalStateException("OpenXR runtime did not provide two stereo views");
            }

            this.viewBuffer = new XrView.Buffer(
                bufferHeap(viewCountNumber, XrView.SIZEOF, XR10.XR_TYPE_VIEW)
            );
            // Check swapchain formats
            error = XR10.xrEnumerateSwapchainFormats(this.session, intBuf, null);
            DeviceCompat.checkResult(error, "xrEnumerateSwapchainFormats(count)");

            // Get swapchain formats
            LongBuffer swapchainFormats = stack.callocLong(intBuf.get(0));
            error = XR10.xrEnumerateSwapchainFormats(this.session, intBuf, swapchainFormats);
            DeviceCompat.checkResult(error, "xrEnumerateSwapchainFormats(list)");

            long[] desiredSwapchainFormats = this.device.getPreferredSwapchainFormats();

            // Choose format
            long chosenFormat = 0;
            for (long glFormatIter : desiredSwapchainFormats) {
                swapchainFormats.rewind();
                while (swapchainFormats.hasRemaining()) {
                    if (glFormatIter == swapchainFormats.get()) {
                        chosenFormat = glFormatIter;
                        break;
                    }
                }
                if (chosenFormat != 0) {
                    break;
                }
            }

            if (chosenFormat == 0) {
                var formats = new ArrayList<Long>();
                swapchainFormats.rewind();
                while (swapchainFormats.hasRemaining()) {
                    formats.add(swapchainFormats.get());
                }
                throw new RuntimeException("No compatible swapchain / framebuffer format available: " + formats);
            }

            this.swapchain = new XrSwapchain[2];
            // Make swapchain
            for(int i = 0; i < 2; i++) {
                XrViewConfigurationView viewConfig = views.get(i);
                XrSwapchainCreateInfo swapchainCreateInfo = XrSwapchainCreateInfo.calloc(stack);
                swapchainCreateInfo.type(XR10.XR_TYPE_SWAPCHAIN_CREATE_INFO);
                swapchainCreateInfo.next(NULL);
                swapchainCreateInfo.createFlags(0);
                swapchainCreateInfo.usageFlags(this.device.getSwapchainUsageFlags());
                swapchainCreateInfo.format(chosenFormat);
                swapchainCreateInfo.sampleCount(1);
                swapchainCreateInfo.width(viewConfig.recommendedImageRectWidth());
                swapchainCreateInfo.height(viewConfig.recommendedImageRectHeight());
                swapchainCreateInfo.faceCount(1);
                swapchainCreateInfo.arraySize(1);
                swapchainCreateInfo.mipCount(1);

                PointerBuffer handlePointer = stack.callocPointer(1);
                error = XR10.xrCreateSwapchain(this.session, swapchainCreateInfo, handlePointer);
                DeviceCompat.checkResult(error, "xrCreateSwapchain(format=" + chosenFormat + ")");
                this.swapchain[i] = new XrSwapchain(handlePointer.get(0), this.session);
                this.width = swapchainCreateInfo.width();
                this.height = swapchainCreateInfo.height();
            }
        }
    }

    public long getSystemID() {
        return this.systemID;
    }

    /**
     * Creates an array of XrStructs with their types preset to {@code type}
     */
    static ByteBuffer bufferStack(int capacity, int sizeof, int type) {
        ByteBuffer b = stackCalloc(capacity * sizeof);

        for (int i = 0; i < capacity; i++) {
            b.position(i * sizeof);
            b.putInt(type);
        }
        b.rewind();
        return b;
    }

    private void initInputAndApplication() {
        this.populateInputActions();

        //this.generateActionManifest();
        //this.loadActionManifest();
        this.loadActionHandles();
        this.loadDefaultBindings();
        //this.installApplicationManifest(false);
        this.inputInitialized = true;
    }

    @Override
    public Matrix4fc getControllerComponentTransform(int controllerIndex, String componentName) {
        if (controllerIndex >= 0 && controllerIndex < CONTROLLERS.length && "handgrip".equals(componentName)) {
            // The transform is updated only from a same-frame valid aim/grip
            // pair, and then retained as the controller's calibrated relation.
            return this.aimToGripTransform[controllerIndex];
        }
        return this.identityComponentTransform;
    }

    @Override
    public boolean isControllerAimTracking(int controller) {
        return controller >= 0 && controller < CONTROLLERS.length &&
            this.aimPoseValid[controller] &&
            this.aimPoseFrame[controller] == this.trackingFrameCount &&
            this.aimPoseTime[controller] == this.time;
    }

    @Override
    public boolean isControllerGripTracking(int controller) {
        return controller >= 0 && controller < CONTROLLERS.length &&
            this.gripPoseValid[controller] &&
            this.gripPoseFrame[controller] == this.trackingFrameCount &&
            this.gripPoseTime[controller] == this.time;
    }

    @Override
    public boolean hasCameraTracker() {
        return false;
    }

    @Override
    public List<Long> getOrigins(VRInputAction action) {
        try (MemoryStack stack = MemoryStack.stackPush()) {
            XrBoundSourcesForActionEnumerateInfo info = XrBoundSourcesForActionEnumerateInfo.calloc(stack);
            info.type(XR10.XR_TYPE_BOUND_SOURCES_FOR_ACTION_ENUMERATE_INFO);
            info.next(NULL);
            info.action(this.getInputActionHandle(action));
            IntBuffer buf = stack.callocInt(1);
            int error = XR10.xrEnumerateBoundSourcesForAction(this.session, info, buf, null);
            logError(error, "xrEnumerateBoundSourcesForAction", action.name);

            int size = buf.get();
            if (size <= 0) {
                return List.of(0L);
            }

            buf = stack.callocInt(size);
            LongBuffer longbuf = stack.callocLong(size);
            error = XR10.xrEnumerateBoundSourcesForAction(this.session, info, buf, longbuf);
            logError(error, "xrEnumerateBoundSourcesForAction", action.name);
            long[] array;
            if (longbuf.hasArray()) { //TODO really?
                array = longbuf.array();
            } else {
                longbuf.rewind();
                array = new long[longbuf.remaining()];
                int index = 0;
                while (longbuf.hasRemaining()) {
                    array[index++] = longbuf.get();
                }
            }
            return Arrays.stream(array).boxed().toList();
        }
    }

    @Override
    public String getOriginName(long origin) {
        try (MemoryStack stack = MemoryStack.stackPush()) {
            XrInputSourceLocalizedNameGetInfo info = XrInputSourceLocalizedNameGetInfo.calloc(stack);
            info.type(XR10.XR_TYPE_INPUT_SOURCE_LOCALIZED_NAME_GET_INFO);
            info.next(0);
            info.sourcePath(origin);
            info.whichComponents(XR10.XR_INPUT_SOURCE_LOCALIZED_NAME_COMPONENT_BIT);

            IntBuffer buf = stack.callocInt(1);
            int error = XR10.xrGetInputSourceLocalizedName(this.session, info, buf, null);
            logError(error, "xrGetInputSourceLocalizedName", "get length");

            int size = buf.get();
            if (size <= 0) {
                return "";
            }

            buf = stack.callocInt(size);
            ByteBuffer byteBuffer = stack.calloc(size);
            error = XR10.xrGetInputSourceLocalizedName(this.session, info, buf, byteBuffer);
            logError(error, "xrGetInputSourceLocalizedName", "get String");
            return MemoryUtil.memUTF8(MemoryUtil.memAddress(byteBuffer));
        }
    }

    @Override
    public VRRenderer createVRRenderer() {
        return new OpenXRStereoRenderer(this);
    }

    @Override
    public boolean isActive() {
        // Starting the session while init() is still building renderer/menu state can leave Quest
        // without a frame loop long enough for the runtime to stop the session. isActive() is
        // queried immediately after VR initialization, so consume READY here instead.
        if (this.initialized && !this.sessionRunning && this.session != null) {
            this.pollVREvents();
        }
        return this.isActive || this.backgroundPolicy.shouldKeepVrRunning(this.sessionRunning);
    }

    /**
     * Parks only a Lab Quest client whose OpenXR session has completed the STOPPING transition.
     * Event polling has already run for this client iteration, and no active frame is delayed.
     */
    public void throttleStoppedSession() {
        long delayNanos = this.backgroundPolicy.stoppedSessionPollDelayNanos(this.sessionRunning);
        if (delayNanos > 0L) {
            if (!this.stoppedSessionThrottleActive) {
                this.stoppedSessionThrottleActive = true;
                this.stoppedSessionThrottleTransition++;
                VRSettings.LOGGER.info(
                    "Vivecraft: Lab Quest stopped-session throttle entered transition={} state={} " +
                        "pollIntervalMs={}",
                    this.stoppedSessionThrottleTransition,
                    sessionStateName(this.sessionState),
                    delayNanos / 1_000_000L);
            }
            this.backgroundPolicy.parkStoppedSession(
                this.sessionRunning, nanos -> LockSupport.parkNanos(this, nanos));
        }
    }

    private void finishStoppedSessionThrottleTransition() {
        if (!this.stoppedSessionThrottleActive) {
            return;
        }
        if (this.backgroundPolicy.isResumedSession(this.sessionRunning)) {
            VRSettings.LOGGER.info(
                "Vivecraft: Lab Quest stopped-session throttle resumed transition={} state={}",
                this.stoppedSessionThrottleTransition,
                sessionStateName(this.sessionState));
            this.stoppedSessionThrottleActive = false;
        } else if (this.backgroundPolicy.isTerminalSessionState()) {
            this.stoppedSessionThrottleActive = false;
        }
    }

    /**
     * Returns whether Minecraft's expensive render body can be skipped for this OpenXR iteration.
     * A begun frame is still ended by the caller so shouldRender=false submits a zero-layer frame.
     */
    public boolean shouldSkipHeavyRender() {
        return this.backgroundPolicy.shouldSkipHeavyRender(
            this.sessionRunning, this.frameBegun, this.shouldRender);
    }

    @Override
    public ControllerType getOriginControllerType(long inputValueHandle) {
        if (inputValueHandle == 0L) {
            return null;
        }

        ControllerType physicalController = this.originControllerTypes.get(inputValueHandle);
        if (physicalController != null) {
            return OpenXRHandedness.logicalController(physicalController, this.reverseHandsForFrame);
        }

        String originPath = pathString(inputValueHandle);
        physicalController = null;
        if (originPath.startsWith(VR.k_pchPathUserHandRight)) {
            physicalController = ControllerType.RIGHT;
        } else if (originPath.startsWith(VR.k_pchPathUserHandLeft)) {
            physicalController = ControllerType.LEFT;
        }
        if (physicalController != null) {
            this.originControllerTypes.put(inputValueHandle, physicalController);
        }
        return OpenXRHandedness.logicalController(physicalController, this.reverseHandsForFrame);
    }

    @Override
    public float getIPD() {
        return this.getEyePosition(RenderPass.RIGHT).x - this.getEyePosition(RenderPass.LEFT).x;
    }

    @Override
    public String getRuntimeName() {
        return "OpenXR";
    }

    //TODO Collect and register all actions
    private void loadActionHandles() {
        for (VRInputActionSet vrinputactionset : VRInputActionSet.values()) {
            long actionSetHandle = makeActionSet(
                this.instance, vrinputactionset.name, vrinputactionset.localizedName, 0);
            this.actionSetHandles.put(vrinputactionset, actionSetHandle);
            this.actionSets.put(vrinputactionset, new XrActionSet(actionSetHandle, this.instance));
        }

        for (VRInputAction vrinputaction : this.inputActions.values()) {
            long action = createAction(vrinputaction.name, vrinputaction.name, vrinputaction.type,
                this.getActionSet(vrinputaction.actionSet), BOTH_HANDS);
            vrinputaction.setHandle(action);
            this.inputActionHandles.put(
                vrinputaction, new XrAction(action, this.getActionSet(vrinputaction.actionSet)));
        }

        setupControllers();

        XrActionSet actionSet = this.getActionSet(VRInputActionSet.GLOBAL);
        this.haptics[RIGHT_CONTROLLER] = createAction("/actions/global/out/righthaptic",
            "/actions/global/out/righthaptic", "haptic", actionSet, BOTH_HANDS);
        this.haptics[LEFT_CONTROLLER] = createAction("/actions/global/out/lefthaptic", "/actions/global/out/lefthaptic",
            "haptic", actionSet, BOTH_HANDS);
        this.hapticActions[RIGHT_CONTROLLER] = new XrAction(this.haptics[RIGHT_CONTROLLER], actionSet);
        this.hapticActions[LEFT_CONTROLLER] = new XrAction(this.haptics[LEFT_CONTROLLER], actionSet);
    }

    private void setupControllers() {
        XrActionSet actionSet = this.getActionSet(VRInputActionSet.GLOBAL);
        this.grip[RIGHT_CONTROLLER] = createAction("/actions/global/in/righthand", "/actions/global/in/righthand",
            "pose", actionSet, BOTH_HANDS);
        this.grip[LEFT_CONTROLLER] = createAction("/actions/global/in/lefthand", "/actions/global/in/lefthand", "pose",
            actionSet, BOTH_HANDS);
        this.aim[RIGHT_CONTROLLER] = createAction("/actions/global/in/righthandaim", "/actions/global/in/righthandaim",
            "pose", actionSet, BOTH_HANDS);
        this.aim[LEFT_CONTROLLER] = createAction("/actions/global/in/lefthandaim", "/actions/global/in/lefthandaim",
            "pose", actionSet, BOTH_HANDS);
        this.gripActions[RIGHT_CONTROLLER] = new XrAction(this.grip[RIGHT_CONTROLLER], actionSet);
        this.gripActions[LEFT_CONTROLLER] = new XrAction(this.grip[LEFT_CONTROLLER], actionSet);
        this.aimActions[RIGHT_CONTROLLER] = new XrAction(this.aim[RIGHT_CONTROLLER], actionSet);
        this.aimActions[LEFT_CONTROLLER] = new XrAction(this.aim[LEFT_CONTROLLER], actionSet);
    }

    private void loadDefaultBindings() {
        try (MemoryStack stack = MemoryStack.stackPush()) {
            int error;
            for (String headset : XRBindings.supportedHeadsets()) {
                VRSettings.LOGGER.info("loading defaults for {}", headset);
                Pair<String, String>[] defaultBindings = XRBindings.getBinding(headset).toArray(new Pair[0]);
                XrActionSuggestedBinding.Buffer bindings = XrActionSuggestedBinding.calloc(defaultBindings.length + 6,
                    stack); //TODO different way of adding controller poses

                for (int i = 0; i < defaultBindings.length; i++) {
                    Pair<String, String> pair = defaultBindings[i];
                    VRInputAction binding = this.getInputActionByName(pair.getLeft());
                    if (binding.handle == 0L) {
                        VRSettings.LOGGER.error("Handle for '{}'/'{}' is null", pair.getLeft(), pair.getRight());
                        continue;
                    }
                    bindings.get(i).set(
                        this.getInputActionHandle(binding),
                        getPath(pair.getRight())
                    );
                }

                //TODO make this also changeable?
                bindings.get(defaultBindings.length).set(
                    this.gripActions[RIGHT_CONTROLLER],
                    getPath("/user/hand/right/input/grip/pose")
                );
                bindings.get(defaultBindings.length + 1).set(
                    this.gripActions[LEFT_CONTROLLER],
                    getPath("/user/hand/left/input/grip/pose")
                );
                bindings.get(defaultBindings.length + 2).set(
                    this.aimActions[RIGHT_CONTROLLER],
                    getPath("/user/hand/right/input/aim/pose")
                );
                bindings.get(defaultBindings.length + 3).set(
                    this.aimActions[LEFT_CONTROLLER],
                    getPath("/user/hand/left/input/aim/pose")
                );

                bindings.get(defaultBindings.length + 4).set(
                    this.hapticActions[RIGHT_CONTROLLER],
                    getPath("/user/hand/right/output/haptic")
                );

                bindings.get(defaultBindings.length + 5).set(
                    this.hapticActions[LEFT_CONTROLLER],
                    getPath("/user/hand/left/output/haptic")
                );

                XrInteractionProfileSuggestedBinding suggested_binds = XrInteractionProfileSuggestedBinding.calloc(
                    stack);
                suggested_binds.type(XR10.XR_TYPE_INTERACTION_PROFILE_SUGGESTED_BINDING);
                suggested_binds.next(NULL);
                suggested_binds.interactionProfile(getPath(headset));
                suggested_binds.suggestedBindings(bindings);

                error = XR10.xrSuggestInteractionProfileBindings(this.instance, suggested_binds);
                logError(error, "xrSuggestInteractionProfileBindings", headset);
            }


            XrSessionActionSetsAttachInfo attach_info = XrSessionActionSetsAttachInfo.calloc(stack);
            attach_info.type(XR10.XR_TYPE_SESSION_ACTION_SETS_ATTACH_INFO);
            attach_info.next(NULL);
            attach_info.actionSets(
                stackPointers(this.actionSetHandles.values().stream().mapToLong(value -> value).toArray()));

            error = XR10.xrAttachSessionActionSets(this.session, attach_info);
            DeviceCompat.checkResult(error, "xrAttachSessionActionSets");

            XrActionSpaceCreateInfo actionSpace = XrActionSpaceCreateInfo.calloc(stack);
            actionSpace.type(XR10.XR_TYPE_ACTION_SPACE_CREATE_INFO);
            actionSpace.next(NULL);
            actionSpace.action(this.gripActions[RIGHT_CONTROLLER]);
            actionSpace.subactionPath(getPath("/user/hand/right"));
            actionSpace.poseInActionSpace(POSE_IDENTITY);
            PointerBuffer pp = stackCallocPointer(1);
            error = XR10.xrCreateActionSpace(this.session, actionSpace, pp);
            DeviceCompat.checkResult(error, "xrCreateActionSpace(grip: /user/hand/right)");
            this.gripSpace[RIGHT_CONTROLLER] = new XrSpace(pp.get(0), this.session);

            actionSpace.action(this.gripActions[LEFT_CONTROLLER]);
            actionSpace.subactionPath(getPath("/user/hand/left"));
            pp.put(0, NULL);
            error = XR10.xrCreateActionSpace(this.session, actionSpace, pp);
            DeviceCompat.checkResult(error, "xrCreateActionSpace(grip: /user/hand/left)");
            this.gripSpace[LEFT_CONTROLLER] = new XrSpace(pp.get(0), this.session);

            actionSpace.action(this.aimActions[RIGHT_CONTROLLER]);
            actionSpace.subactionPath(getPath("/user/hand/right"));
            pp.put(0, NULL);
            error = XR10.xrCreateActionSpace(this.session, actionSpace, pp);
            DeviceCompat.checkResult(error, "xrCreateActionSpace(aim: /user/hand/right)");
            this.aimSpace[RIGHT_CONTROLLER] = new XrSpace(pp.get(0), this.session);

            actionSpace.action(this.aimActions[LEFT_CONTROLLER]);
            actionSpace.subactionPath(getPath("/user/hand/left"));
            pp.put(0, NULL);
            error = XR10.xrCreateActionSpace(this.session, actionSpace, pp);
            DeviceCompat.checkResult(error, "xrCreateActionSpace(aim: /user/hand/left)");
            this.aimSpace[LEFT_CONTROLLER] = new XrSpace(pp.get(0), this.session);
        }
    }

    public long getPath(String pathString) {
        return this.paths.computeIfAbsent(pathString, s -> {
            try (MemoryStack ignored = stackPush()) {
                LongBuffer buf = stackCallocLong(1);
                int error = XR10.xrStringToPath(this.instance, pathString, buf);
                logError(error, "getPath", pathString);
                return buf.get();
            }
        });
    }

    private String processActionName(String name) {
        String s = name.substring(name.lastIndexOf('/') + 1)
            .toLowerCase()
            .replaceAll(" ", "-")
            .replaceAll("[^-_./a-z0-9]", "");

        if (s.length() > 64) {s = s.substring(0, 60) + "...";}
        return s;
    }

    private long createAction(
        String name, String localisedName, String type, XrActionSet actionSet, @Nullable String[] subactionPaths)
    {
        try (MemoryStack stack = MemoryStack.stackPush()) {

            String s = processActionName(name);
            XrActionCreateInfo hands = XrActionCreateInfo.calloc(stack);
            hands.type(XR10.XR_TYPE_ACTION_CREATE_INFO);
            hands.next(NULL);
            hands.actionName(memUTF8(s));
            switch (type) {
                case "boolean" -> hands.actionType(XR10.XR_ACTION_TYPE_BOOLEAN_INPUT);
                case "vector1" -> hands.actionType(XR10.XR_ACTION_TYPE_FLOAT_INPUT);
                case "vector2" -> hands.actionType(XR10.XR_ACTION_TYPE_VECTOR2F_INPUT);
                case "pose" -> hands.actionType(XR10.XR_ACTION_TYPE_POSE_INPUT);
                case "haptic" -> hands.actionType(XR10.XR_ACTION_TYPE_VIBRATION_OUTPUT);
            }
            if (subactionPaths != null) {
                LongBuffer buffer = stackCallocLong(subactionPaths.length);
                for (String path : subactionPaths) {
                    buffer.put(getPath(path));
                }
                hands.countSubactionPaths(subactionPaths.length);
                hands.subactionPaths(buffer.rewind());
            } else {
                hands.countSubactionPaths(0);
                hands.subactionPaths(null);
            }
            hands.localizedActionName(memUTF8(s));
            PointerBuffer buffer = stackCallocPointer(1);

            int error = XR10.xrCreateAction(actionSet, hands, buffer);
            logError(error, "xrCreateAction", "name:", name, "type:", type);
            return buffer.get(0);
        }
    }

    private long makeActionSet(XrInstance instance, String name, String localisedName, int priority) {
        try (MemoryStack stack = MemoryStack.stackPush()) {
            XrActionSetCreateInfo info = XrActionSetCreateInfo.calloc(stack);
            info.type(XR10.XR_TYPE_ACTION_SET_CREATE_INFO);
            info.next(NULL);
            info.actionSetName(memUTF8(localisedName.toLowerCase()));
            info.localizedActionSetName(memUTF8(localisedName.toLowerCase()));
            info.priority(priority);
            PointerBuffer buffer = stack.callocPointer(1);

            int error = XR10.xrCreateActionSet(instance, info, buffer);
            logError(error, "makeActionSet", localisedName.toLowerCase());
            return buffer.get(0);
        }
    }

    static ByteBuffer bufferHeap(int capacity, int sizeof, int type) {
        ByteBuffer b = memCalloc(capacity * sizeof);

        for (int i = 0; i < capacity; i++) {
            b.position(i * sizeof);
            b.putInt(type);
        }
        b.rewind();
        return b;
    }

    /**
     * gets the String for the given xrResult
     */
    private String getResultName(int xrResult) {
        String resultString = switch (xrResult) {
            case 1 -> "XR_TIMEOUT_EXPIRED";
            case 3 -> "XR_SESSION_LOSS_PENDING";
            case 4 -> "XR_EVENT_UNAVAILABLE";
            case 7 -> "XR_SPACE_BOUNDS_UNAVAILABLE";
            case 8 -> "XR_SESSION_NOT_FOCUSED";
            case 9 -> "XR_FRAME_DISCARDED";
            case -1 -> "XR_ERROR_VALIDATION_FAILURE";
            case -2 -> "XR_ERROR_RUNTIME_FAILURE";
            case -3 -> "XR_ERROR_OUT_OF_MEMORY";
            case -4 -> "XR_ERROR_API_VERSION_UNSUPPORTED";
            case -6 -> "XR_ERROR_INITIALIZATION_FAILED";
            case -7 -> "XR_ERROR_FUNCTION_UNSUPPORTED";
            case -8 -> "XR_ERROR_FEATURE_UNSUPPORTED";
            case -9 -> "XR_ERROR_EXTENSION_NOT_PRESENT";
            case -10 -> "XR_ERROR_LIMIT_REACHED";
            case -11 -> "XR_ERROR_SIZE_INSUFFICIENT";
            case -12 -> "XR_ERROR_HANDLE_INVALID";
            case -13 -> "XR_ERROR_INSTANCE_LOST";
            case -14 -> "XR_ERROR_SESSION_RUNNING";
            case -16 -> "XR_ERROR_SESSION_NOT_RUNNING";
            case -17 -> "XR_ERROR_SESSION_LOST";
            case -18 -> "XR_ERROR_SYSTEM_INVALID";
            case -19 -> "XR_ERROR_PATH_INVALID";
            case -20 -> "XR_ERROR_PATH_COUNT_EXCEEDED";
            case -21 -> "XR_ERROR_PATH_FORMAT_INVALID";
            case -22 -> "XR_ERROR_PATH_UNSUPPORTED";
            case -23 -> "XR_ERROR_LAYER_INVALID";
            case -24 -> "XR_ERROR_LAYER_LIMIT_EXCEEDED";
            case -25 -> "XR_ERROR_SWAPCHAIN_RECT_INVALID";
            case -26 -> "XR_ERROR_SWAPCHAIN_FORMAT_UNSUPPORTED";
            case -27 -> "XR_ERROR_ACTION_TYPE_MISMATCH";
            case -28 -> "XR_ERROR_SESSION_NOT_READY";
            case -29 -> "XR_ERROR_SESSION_NOT_STOPPING";
            case -30 -> "XR_ERROR_TIME_INVALID";
            case -31 -> "XR_ERROR_REFERENCE_SPACE_UNSUPPORTED";
            case -32 -> "XR_ERROR_FILE_ACCESS_ERROR";
            case -33 -> "XR_ERROR_FILE_CONTENTS_INVALID";
            case -34 -> "XR_ERROR_FORM_FACTOR_UNSUPPORTED";
            case -35 -> "XR_ERROR_FORM_FACTOR_UNAVAILABLE";
            case -36 -> "XR_ERROR_API_LAYER_NOT_PRESENT";
            case -37 -> "XR_ERROR_CALL_ORDER_INVALID";
            case -38 -> "XR_ERROR_GRAPHICS_DEVICE_INVALID";
            case -39 -> "XR_ERROR_POSE_INVALID";
            case -40 -> "XR_ERROR_INDEX_OUT_OF_RANGE";
            case -41 -> "XR_ERROR_VIEW_CONFIGURATION_TYPE_UNSUPPORTED";
            case -42 -> "XR_ERROR_ENVIRONMENT_BLEND_MODE_UNSUPPORTED";
            case -44 -> "XR_ERROR_NAME_DUPLICATED";
            case -45 -> "XR_ERROR_NAME_INVALID";
            case -46 -> "XR_ERROR_ACTIONSET_NOT_ATTACHED";
            case -47 -> "XR_ERROR_ACTIONSETS_ALREADY_ATTACHED";
            case -48 -> "XR_ERROR_LOCALIZED_NAME_DUPLICATED";
            case -49 -> "XR_ERROR_LOCALIZED_NAME_INVALID";
            case -50 -> "XR_ERROR_GRAPHICS_REQUIREMENTS_CALL_MISSING";
            case -51 -> "XR_ERROR_RUNTIME_UNAVAILABLE";
            default -> null;
        };
        if (resultString == null) {
            // ask the runtime for the xrResult name
            try (MemoryStack stack = MemoryStack.stackPush()) {
                ByteBuffer str = stack.calloc(XR10.XR_MAX_RESULT_STRING_SIZE);

                if (XR10.xrResultToString(this.instance, xrResult, str) == XR10.XR_SUCCESS) {
                    resultString = (memUTF8(memAddress(str)));
                } else {
                    resultString = "Unknown Error: " + xrResult;
                }
            }
        }
        return resultString;
    }

    private static String sessionStateName(int state) {
        return switch (state) {
            case XR10.XR_SESSION_STATE_IDLE -> "IDLE";
            case XR10.XR_SESSION_STATE_READY -> "READY";
            case XR10.XR_SESSION_STATE_SYNCHRONIZED -> "SYNCHRONIZED";
            case XR10.XR_SESSION_STATE_VISIBLE -> "VISIBLE";
            case XR10.XR_SESSION_STATE_FOCUSED -> "FOCUSED";
            case XR10.XR_SESSION_STATE_STOPPING -> "STOPPING";
            case XR10.XR_SESSION_STATE_LOSS_PENDING -> "LOSS_PENDING";
            case XR10.XR_SESSION_STATE_EXITING -> "EXITING";
            default -> "UNKNOWN(" + state + ")";
        };
    }

    /**
     * logs only errors
     *
     * @param xrResult result to check
     * @param caller   where the xrResult came from
     * @param args     arguments may be helpful in locating the error
     */
    protected void logError(int xrResult, String caller, String... args) {
        if (xrResult < 0) {
            VRSettings.LOGGER.error("{} for {} errored: {}", caller, String.join(" ", args), getResultName(xrResult));
        }
    }
}
