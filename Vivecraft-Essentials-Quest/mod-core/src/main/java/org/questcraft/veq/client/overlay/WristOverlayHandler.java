package org.questcraft.veq.client.overlay;

import com.mojang.blaze3d.pipeline.RenderTarget;
import net.minecraft.client.gui.screens.Screen;
import net.minecraft.client.gui.screens.inventory.AbstractContainerScreen;
import net.minecraft.world.item.ItemStack;
import net.minecraft.world.item.ShieldItem;
import org.joml.Matrix4f;
import org.joml.Matrix4fc;
import org.joml.Quaternionf;
import org.joml.Vector2f;
import org.joml.Vector3f;
import org.joml.Vector3fc;
import org.questcraft.veq.client.config.VepFeatureConfig;
import org.questcraft.veq.client.config.WristPoseProfile;
import org.questcraft.veq.client.config.WristUiConfig;
import org.questcraft.veq.client.gui.VepInventoryLayout;
import org.questcraft.veq.client.wrist.WristCalibrationMode;
import org.questcraft.veq.client.wrist.WristCalibrationMath;
import org.questcraft.veq.client.wrist.WristInputOwnership;
import org.questcraft.veq.client.wrist.WristOverlayPoseMath;
import org.questcraft.veq.client.wrist.WristSurfaceMath;
import org.questcraft.veq.client.wrist.VepSurfaceVisibilityPolicy;
import org.vivecraft.client.VivecraftVRMod;
import org.vivecraft.client_vr.ClientDataHolderVR;
import org.vivecraft.client_vr.VRData;
import org.vivecraft.client_vr.gameplay.screenhandlers.ExternalScreenOverlayHandler;
import org.vivecraft.client_vr.gameplay.screenhandlers.GuiHandler;
import org.vivecraft.client_vr.provider.ControllerType;
import org.vivecraft.client_vr.provider.HandedKeyBinding;
import org.vivecraft.client_vr.render.helpers.RenderHelper;
import org.vivecraft.common.utils.MathUtils;
import org.vivecraft.data.ViveItemTags;

import org.jetbrains.annotations.Nullable;

/**
 * Dedicated wrist screen surface. It never becomes Minecraft's active screen
 * and never writes to {@code GuiHandler.GUI_*} state.
 */
public final class WristOverlayHandler implements ExternalScreenOverlayHandler.Overlay {
    public static final int SURFACE_PRIORITY = 50;
    public static final String SURFACE_ID = VepUiFeatureLayer.INVENTORY_SURFACE_ID;
    // Match VEP/Visor's effective 16:9 GUI canvas. The 258 px inventory is
    // ~0.403 m wide at the default 0.5 surface scale instead of the oversized
    // ~0.537 m produced by the old 360 px target.
    public static final int SCALED_WIDTH = VepSurfaceSizing.LOGICAL_WIDTH;
    public static final int SCALED_HEIGHT = VepSurfaceSizing.LOGICAL_HEIGHT;
    public static final int RENDER_WIDTH = VepSurfaceSizing.RENDER_WIDTH;
    public static final int RENDER_HEIGHT = VepSurfaceSizing.RENDER_HEIGHT;
    private static final WristOverlayHandler INSTANCE = new WristOverlayHandler();

    private final Vector3f roomPosition = new Vector3f();
    private final Matrix4f roomRotation = new Matrix4f();
    private final Vector3f offsetScratch = new Vector3f();
    private final Quaternionf localRotationScratch = new Quaternionf();
    private final Vector3f rayDirection = new Vector3f();
    private final Vector3f rayNormal = new Vector3f();
    private final Vector3f rayRight = new Vector3f();
    private final Vector3f rayUp = new Vector3f();
    private final Vector3f rayTopLeft = new Vector3f();
    private final Vector3f rayDelta = new Vector3f();
    private final Vector3f rayIntersection = new Vector3f();
    private final Vector2f rayUv = new Vector2f();
    private final boolean[] pressed = new boolean[ControllerType.values().length];
    private final ExternalScreenOverlayHandler.PointerButton[] pressedButtons =
            new ExternalScreenOverlayHandler.PointerButton[ControllerType.values().length];
    private final ManualVisibilityLatch manualVisibility = new ManualVisibilityLatch();
    private final VepWristFrameRedrawGate redrawGate = new VepWristFrameRedrawGate();

    @Nullable
    private Screen pendingRedrawScreen;
    private long pendingRedrawFrameTimeNanos = Long.MIN_VALUE;
    private int pendingRedrawHoverKey = -1;

    private final Matrix4f calibrationStartControllerRotation = new Matrix4f();
    private final Matrix4f calibrationStartControllerInverse = new Matrix4f();
    private final Matrix4f calibrationStartOverlayRotation = new Matrix4f();
    private final Matrix4f calibrationDeltaRotation = new Matrix4f();
    private final Matrix4f calibrationAnchorInverse = new Matrix4f();
    private final Matrix4f calibrationRoomRotation = new Matrix4f();
    private final Matrix4f calibrationLocalRotation = new Matrix4f();
    private final Vector3f calibrationStartControllerPosition = new Vector3f();
    private final Vector3f calibrationStartOverlayPosition = new Vector3f();
    private final Vector3f calibrationStartOffsetFromController = new Vector3f();
    private final Vector3f calibrationRoomPosition = new Vector3f();
    private final Vector3f calibrationLocalOffset = new Vector3f();
    private final Quaternionf calibrationLocalQuaternion = new Quaternionf();

    @Nullable
    private WristOverlayView view;
    private boolean showing;
    private boolean hidePending;
    private boolean calibrating;
    private boolean calibrationGripWasDown;
    private boolean calibrationDragging;
    private WristCalibrationMode calibrationMode = WristCalibrationMode.MOVE_ROTATE;
    private float calibrationStartScale;
    private float calibrationStartControllerDistance;
    private float scale = 0.5F;
    private ControllerType anchorController = ControllerType.LEFT;

    private WristOverlayHandler() {
    }

    public static void installView(WristOverlayView candidate) {
        if (candidate == null) {
            throw new IllegalArgumentException("Wrist overlay view cannot be null");
        }
        INSTANCE.setVisibleInternal(false, true);
        INSTANCE.view = candidate;
        INSTANCE.redrawGate.invalidate();
        ExternalScreenOverlayHandler.register(INSTANCE);
    }

    public static void setVisible(boolean visible) {
        INSTANCE.setVisibleInternal(visible, false);
    }

    public static void forceHide() {
        INSTANCE.manualVisibility.clear();
        INSTANCE.setVisibleInternal(false, true);
    }

    public static boolean isVisible() {
        return INSTANCE.showing;
    }

    public static boolean isPointerFocused(ControllerType controller) {
        return INSTANCE.isUsingController(controller);
    }

    public static boolean isCalibrating() {
        return INSTANCE.calibrating;
    }

    public static void toggleManualVisibility(boolean canOpen) {
        INSTANCE.manualVisibility.toggle(true, canOpen);
    }

    public static void tickManualVisibility(boolean stillValid) {
        INSTANCE.manualVisibility.tick(stillValid);
    }

    public static boolean isManualVisibilityForced() {
        return INSTANCE.manualVisibility.forcesVisible();
    }

    static Vector3fc roomPositionView() {
        return INSTANCE.roomPosition;
    }

    static Matrix4fc roomRotationView() {
        return INSTANCE.roomRotation;
    }

    static float surfaceScale() {
        return INSTANCE.scale;
    }

    public static void beginCalibration(WristCalibrationMode mode) {
        INSTANCE.calibrating = true;
        INSTANCE.calibrationMode = mode == null ? WristCalibrationMode.MOVE_ROTATE : mode;
        INSTANCE.stopCalibrationDrag();
        INSTANCE.setVisibleInternal(true, false);
    }

    public static void setCalibrationMode(WristCalibrationMode mode) {
        INSTANCE.calibrationMode = mode == null ? WristCalibrationMode.MOVE_ROTATE : mode;
        INSTANCE.stopCalibrationDrag();
    }

    public static void endCalibration() {
        INSTANCE.calibrating = false;
        INSTANCE.stopCalibrationDrag();
    }

    /** Stops a live Grip grab before a fine edit changes the same draft pose. */
    public static void cancelCalibrationGrab() {
        INSTANCE.stopCalibrationDrag();
    }

    /** Re-composes the current settings draft into the exact rendered pose. */
    public static void refreshCalibrationPreview() {
        INSTANCE.refreshCalibrationPreviewInternal();
    }

    public static void updateRoomPose(
            WristUiConfig config,
            VRData.VRDevicePose aim
    ) {
        INSTANCE.updateRoomPoseInternal(config, aim);
    }

    /** Tests only the controller opposite the wrist anchor against panel bounds. */
    public static boolean isOtherHandAimingAt(float minU, float minV, float maxU, float maxV) {
        return INSTANCE.isOtherHandAimingAtInternal(minU, minV, maxU, maxV);
    }

    /**
     * Evaluates VEP acquisition against this handler's final calibrated pose,
     * bounds and scale. Rendering, pointer hit-testing and visibility therefore
     * all observe the same settings draft and the same {@code Flip Face}.
     */
    public static boolean updateVisibility(
            VepSurfaceVisibilityPolicy policy,
            VRData.VRDevicePose hmd,
            long nowMillis,
            long openDelayMillis,
            long closeDelayMillis
    ) {
        return INSTANCE.updateVisibilityInternal(
                policy,
                hmd,
                nowMillis,
                openDelayMillis,
                closeDelayMillis
        );
    }

    private void setVisibleInternal(boolean visible, boolean force) {
        boolean next = visible && this.view != null;
        if (!force && !next && this.showing && this.view != null && !this.view.canHide()) {
            this.hidePending = true;
            return;
        }
        if (this.showing == next) {
            if (next) {
                this.hidePending = false;
            } else if (force && this.view != null) {
                // A lifecycle transition may arrive after a soft hide. Still
                // give the view a hard-close opportunity so no old menu can
                // retain a carried stack unnoticed.
                cancelAll();
                this.view.onHidden(true);
                this.redrawGate.invalidate();
            }
            return;
        }

        this.showing = next;
        this.hidePending = false;
        this.redrawGate.invalidate();
        if (next) {
            this.view.init(SCALED_WIDTH, SCALED_HEIGHT);
            this.view.onShown();
        } else {
            cancelAll();
            if (this.view != null) {
                this.view.onHidden(force);
            }
        }
    }

    private void updateRoomPoseInternal(
            WristUiConfig config,
            VRData.VRDevicePose aim
    ) {
        this.anchorController = ControllerType.values()[config.hand().controllerIndex()];
        WristPoseProfile pose = config.pose(this.anchorController);
        // Schema 3 stores this deterministic local Rz * Ry * Rx result as a
        // quaternion, avoiding the old per-frame Euler order ambiguity.
        WristOverlayPoseMath.composeAimPose(
                aim.getMatrix(),
                aim.getPositionF(),
                pose,
                this.roomPosition,
                this.roomRotation,
                this.offsetScratch,
                this.localRotationScratch
        );
        this.scale = pose.scale();
    }

    private boolean isOtherHandAimingAtInternal(float minU, float minV, float maxU, float maxV) {
        ControllerType pointerController = this.anchorController == ControllerType.RIGHT
                ? ControllerType.LEFT
                : ControllerType.RIGHT;
        ClientDataHolderVR dataHolder = ClientDataHolderVR.getInstance();
        int index = pointerController.ordinal();
        if (dataHolder.vr == null || !dataHolder.vr.isControllerTracking(index) ||
                dataHolder.vrPlayer.vrdata_room_pre == null) {
            return false;
        }
        VRData.VRDevicePose pointer = dataHolder.vrPlayer.vrdata_room_pre.getController(index);
        if (pointer == null) {
            return false;
        }
        // Vivecraft controller AIM rays point down local -Z. Using +Z makes
        // the pointer travel backwards and forces the user to twist the
        // controller through an unnatural angle before it can hit the wrist.
        pointer.getMatrix().transformDirection(MathUtils.BACK, this.rayDirection).normalize();
        float aspect = (float) SCALED_HEIGHT / (float) SCALED_WIDTH;
        return WristSurfaceMath.rayToUv(
                pointer.getPositionF(),
                this.rayDirection,
                this.roomPosition,
                this.roomRotation,
                this.scale,
                aspect,
                this.rayUv,
                this.rayNormal,
                this.rayRight,
                this.rayUp,
                this.rayTopLeft,
                this.rayDelta,
                this.rayIntersection
        ) && WristSurfaceMath.isWithin(this.rayUv, minU, minV, maxU, maxV);
    }

    private boolean updateVisibilityInternal(
            VepSurfaceVisibilityPolicy policy,
            VRData.VRDevicePose hmd,
            long nowMillis,
            long openDelayMillis,
            long closeDelayMillis
    ) {
        if (policy == null || hmd == null || this.view == null) {
            return false;
        }

        ControllerType pointerController = this.anchorController == ControllerType.RIGHT
                ? ControllerType.LEFT
                : ControllerType.RIGHT;
        ClientDataHolderVR dataHolder = ClientDataHolderVR.getInstance();
        VRData roomData = dataHolder.vrPlayer.vrdata_room_pre;
        VRData.VRDevicePose pointer = null;
        if (roomData != null && dataHolder.vr != null
                && dataHolder.vr.isControllerTracking(pointerController.ordinal())) {
            pointer = roomData.getController(pointerController.ordinal());
        }

        ExternalScreenOverlayHandler.SurfaceBounds bounds = bounds();
        float minU;
        float minV;
        float maxU;
        float maxV;
        if (bounds.isFull() && this.view.screen() == null) {
            minU = (SCALED_WIDTH - VepInventoryLayout.PANEL_WIDTH) * 0.5F / SCALED_WIDTH;
            minV = (SCALED_HEIGHT - VepInventoryLayout.PANEL_HEIGHT) * 0.5F / SCALED_HEIGHT;
            maxU = minU + (float) VepInventoryLayout.PANEL_WIDTH / SCALED_WIDTH;
            maxV = minV + (float) VepInventoryLayout.PANEL_HEIGHT / SCALED_HEIGHT;
        } else if (bounds.isFull()) {
            minU = 0.0F;
            minV = 0.0F;
            maxU = 1.0F;
            maxV = 1.0F;
        } else {
            minU = (float) bounds.x() / (float) SCALED_WIDTH;
            minV = (float) bounds.y() / (float) SCALED_HEIGHT;
            maxU = (float) (bounds.x() + bounds.width()) / (float) SCALED_WIDTH;
            maxV = (float) (bounds.y() + bounds.height()) / (float) SCALED_HEIGHT;
        }
        float aspect = (float) SCALED_HEIGHT / (float) SCALED_WIDTH;
        return policy.update(
                nowMillis,
                hmd.getPositionF(),
                hmd.getMatrix(),
                MathUtils.BACK,
                pointer == null ? null : pointer.getPositionF(),
                pointer == null ? null : pointer.getMatrix(),
                MathUtils.BACK,
                this.roomPosition,
                this.roomRotation,
                this.scale,
                aspect,
                minU,
                minV,
                maxU,
                maxV,
                this.manualVisibility.forcesVisible(),
                shouldRetainVisibility(),
                openDelayMillis,
                closeDelayMillis
        );
    }

    private boolean shouldRetainVisibility() {
        if (!this.showing || this.view == null) {
            return false;
        }
        if (!this.view.canHide()) {
            return true;
        }
        for (ControllerType controller : ControllerType.values()) {
            if (controller != this.anchorController && this.view.isPointerFocused(controller)) {
                return true;
            }
        }
        return false;
    }

    private void cancelAll() {
        if (this.view == null) {
            for (int i = 0; i < this.pressed.length; i++) {
                this.pressed[i] = false;
                this.pressedButtons[i] = null;
            }
            return;
        }
        for (ControllerType controller : ControllerType.values()) {
            int index = controller.ordinal();
            if (this.pressed[index]) {
                this.view.cancel(controller, this.pressedButtons[index] == null
                        ? ExternalScreenOverlayHandler.PointerButton.PRIMARY
                        : this.pressedButtons[index]);
            }
            this.pressed[index] = false;
            this.pressedButtons[index] = null;
        }
    }

    @Override
    public String id() {
        return SURFACE_ID;
    }

    @Override
    public String name() {
        return "Vivecraft Essentials Quest Wrist";
    }

    @Override
    @Nullable
    public Screen screen() {
        return this.view == null ? null : this.view.screen();
    }

    @Override
    public boolean isShowing() {
        return this.showing;
    }

    @Override
    public Vector3fc roomPosition() {
        return this.roomPosition;
    }

    @Override
    public Matrix4fc roomRotation() {
        return this.roomRotation;
    }

    @Override
    public float scale() {
        return this.scale;
    }

    @Override
    public int priority() {
        return SURFACE_PRIORITY;
    }

    @Override
    public boolean shouldHideHeldItem(ControllerType controller, ItemStack stack) {
        boolean shieldLike = stack != null &&
            (stack.getItem() instanceof ShieldItem || stack.is(ViveItemTags.VIVECRAFT_SHIELDS));
        return WristHeldItemRenderPolicy.shouldHide(
            this.showing, this.anchorController, controller, shieldLike);
    }

    @Override
    public int renderWidth() {
        return RENDER_WIDTH;
    }

    @Override
    public int renderHeight() {
        return RENDER_HEIGHT;
    }

    @Override
    public int scaledWidth() {
        return SCALED_WIDTH;
    }

    @Override
    public int scaledHeight() {
        return SCALED_HEIGHT;
    }

    @Override
    public boolean usesMipmaps() {
        // The 1008x540 wrist target is sampled close to its native density.
        // Avoid allocating and regenerating a mip chain on every dirty frame.
        return false;
    }

    @Override
    public boolean usesRetainedContentTarget() {
        // Screen extraction is retained separately; the core still clears and
        // recomposes the presentation target every frame for a smooth pointer
        // and carried item with no stale pixels after either disappears.
        return true;
    }

    @Override
    public ExternalScreenOverlayHandler.SurfaceBounds bounds() {
        return this.view == null
                ? ExternalScreenOverlayHandler.SurfaceBounds.full()
                : this.view.bounds();
    }

    @Override
    public ExternalScreenOverlayHandler.RenderCursor cursor(ControllerType controller) {
        return this.view == null
                ? ExternalScreenOverlayHandler.RenderCursor.invalid()
                : this.view.renderCursor(controller);
    }

    @Override
    public void resize(int scaledWidth, int scaledHeight) {
        this.redrawGate.invalidate();
        if (this.view != null) {
            cancelAll();
            this.view.init(scaledWidth, scaledHeight);
        }
    }

    @Override
    public void processGui() {
        if (!this.showing || this.view == null) {
            return;
        }
        if (this.hidePending && this.view.canHide()) {
            setVisibleInternal(false, false);
            return;
        }
        if (this.calibrating) {
            cancelAll();
            for (ControllerType controller : ControllerType.values()) {
                this.view.clearPointer(controller);
            }
            updateCalibrationDrag();
            return;
        }
        for (ControllerType controller : ControllerType.values()) {
            if (controller == this.anchorController) {
                this.view.clearPointer(controller);
                continue;
            }
            this.view.updatePointer(controller, this.roomPosition, this.roomRotation, this.scale);
        }
    }

    @Override
    public void processBindings() {
        // Pointer buttons and scroll are dispatched centrally by
        // ExternalScreenOverlayHandler. Calibration bindings remain separate.
    }

    @Override
    public boolean handlesPointerEvents() {
        return true;
    }

    @Override
    public void pointerPressed(ControllerType controller,
                               ExternalScreenOverlayHandler.RenderCursor cursor,
                               ExternalScreenOverlayHandler.PointerButton button) {
        if (!this.showing || this.view == null || this.calibrating ||
                controller == this.anchorController
                || !this.view.acceptsPointerPress(controller, button)) {
            return;
        }
        int index = controller.ordinal();
        if (this.pressed[index]) {
            return;
        }
        if (this.view.press(controller, button)) {
            this.pressed[index] = true;
            this.pressedButtons[index] = button;
            this.redrawGate.invalidate();
        }
    }

    @Override
    public void pointerReleased(ControllerType controller,
                                ExternalScreenOverlayHandler.RenderCursor cursor,
                                ExternalScreenOverlayHandler.PointerButton button) {
        int index = controller.ordinal();
        if (this.view != null && this.pressed[index]) {
            this.view.release(controller, this.pressedButtons[index] == null
                    ? button
                    : this.pressedButtons[index]);
        }
        this.pressed[index] = false;
        this.pressedButtons[index] = null;
        this.redrawGate.invalidate();
    }

    @Override
    public void pointerCancelled(ControllerType controller,
                                 ExternalScreenOverlayHandler.PointerButton button) {
        int index = controller.ordinal();
        if (this.view != null && this.pressed[index]) {
            this.view.cancel(controller, this.pressedButtons[index] == null
                    ? button
                    : this.pressedButtons[index]);
        }
        this.pressed[index] = false;
        this.pressedButtons[index] = null;
        this.redrawGate.invalidate();
    }

    @Override
    public void pointerScrolled(ControllerType controller,
                                ExternalScreenOverlayHandler.RenderCursor cursor,
                                double amount) {
        if (this.view != null && this.view.isPointerFocused(controller)) {
            this.view.scroll(controller, amount);
            this.redrawGate.invalidate();
        }
    }

    @Override
    public boolean isUsingController(ControllerType controller) {
        // Calibration is the highest-priority two-hand interaction: the
        // anchor supplies the reference pose and the opposite hand edits it.
        return WristInputOwnership.ownsController(
                this.showing,
                this.view != null,
                this.calibrating,
                controller,
                this.view != null && controller != null && this.view.ownsInput(controller)
        );
    }

    @Override
    public ExternalScreenOverlayHandler.RenderCursor renderCursor() {
        return this.view == null
                ? ExternalScreenOverlayHandler.RenderCursor.invalid()
                : this.view.renderCursor();
    }

    @Override
    public boolean shouldRedraw(
            long frameTimeNanos,
            ExternalScreenOverlayHandler.RenderCursor cursor
    ) {
        Screen activeScreen = screen();
        int hoverKey = hoverKey(cursor);
        this.pendingRedrawFrameTimeNanos = frameTimeNanos;
        this.pendingRedrawScreen = activeScreen;
        this.pendingRedrawHoverKey = hoverKey;
        return this.redrawGate.shouldRedraw(
                frameTimeNanos,
                activeScreen,
                hoverKey,
                VepFeatureConfig.getInstance().showPlayerPreview()
        );
    }

    @Override
    public void redrawCompleted(
            long frameTimeNanos,
            ExternalScreenOverlayHandler.RenderCursor cursor
    ) {
        if (this.pendingRedrawFrameTimeNanos == frameTimeNanos) {
            this.redrawGate.markRendered(
                    frameTimeNanos,
                    this.pendingRedrawScreen,
                    this.pendingRedrawHoverKey
            );
            return;
        }
        // Defensive fallback for callers that render without a preceding
        // decision. It still commits only after the draw completed.
        Screen activeScreen = screen();
        this.redrawGate.markRendered(frameTimeNanos, activeScreen, hoverKey(cursor));
    }

    @Override
    public void renderSurface(
            RenderTarget target,
            ExternalScreenOverlayHandler.RenderCursor cursor
    ) {
        Screen activeScreen = screen();
        if (target == null || activeScreen == null) {
            return;
        }
        int mouseX = cursor != null && cursor.valid()
                ? VepSurfacePointerRenderer.screenMouseCoordinate(cursor.x())
                : -10_000;
        int mouseY = cursor != null && cursor.valid()
                ? VepSurfacePointerRenderer.screenMouseCoordinate(cursor.y())
                : -10_000;
        if (activeScreen instanceof AbstractContainerScreen<?> containerScreen) {
            ContextualContainerRenderPass.withCarriedDeferred(
                    containerScreen,
                    () -> RenderHelper.drawScreen(containerScreen, true, mouseX, mouseY)
            );
        } else {
            RenderHelper.drawScreen(activeScreen, true, mouseX, mouseY);
        }
    }

    @Override
    public void renderCarriedItem(
            RenderTarget target,
            ExternalScreenOverlayHandler.RenderCursor cursor
    ) {
        Screen activeScreen = screen();
        if (target == null
                || !(activeScreen instanceof AbstractContainerScreen<?> containerScreen)) {
            return;
        }
        boolean pointerRenderable = VepSurfacePointerRenderer.canRender(
                cursor, SCALED_WIDTH, SCALED_HEIGHT);
        boolean carriedStackPresent = !containerScreen.getMenu().getCarried().isEmpty();
        if (!VepWristRenderPassPolicy.shouldRun(pointerRenderable, carriedStackPresent)) {
            return;
        }
        // Compose the pointer first and Vanilla's carried stack in the
        // following stratum on this exact framebuffer. A separate coplanar
        // quad caused the Held badge to flicker in the headset.
        VepSurfacePointerRenderer.renderPointerWithCarriedAbove(
                target,
                containerScreen,
                cursor,
                SCALED_WIDTH,
                SCALED_HEIGHT,
                bounds()
        );
    }

    private int hoverKey(@Nullable ExternalScreenOverlayHandler.RenderCursor cursor) {
        if (this.view == null || cursor == null || !cursor.valid()) {
            return -1;
        }
        return this.view.hoverKey(cursor.controller());
    }

    private void updateCalibrationDrag() {
        ClientDataHolderVR dataHolder = ClientDataHolderVR.getInstance();
        VRData roomData = dataHolder.vrPlayer.vrdata_room_pre;
        if (roomData == null || dataHolder.vr == null) {
            stopCalibrationDrag();
            return;
        }
        ControllerType controller = this.anchorController == ControllerType.RIGHT
                ? ControllerType.LEFT
                : ControllerType.RIGHT;
        boolean gripDown = calibrationGripDown(dataHolder, controller);
        VRData.VRDevicePose pointer = roomData.getController(controller.ordinal());
        VRData.VRDevicePose anchor = roomData.getController(this.anchorController.ordinal());
        if (pointer == null || anchor == null) {
            stopCalibrationDrag();
            return;
        }

        if (gripDown && !this.calibrationGripWasDown) {
            this.calibrationDragging = true;
            this.calibrationStartControllerRotation.set(pointer.getMatrix());
            this.calibrationStartControllerPosition.set(pointer.getPositionF());
            this.calibrationStartOverlayRotation.set(this.roomRotation);
            this.calibrationStartOverlayPosition.set(this.roomPosition);
            this.calibrationStartScale = this.scale;
            this.calibrationStartControllerDistance = Math.max(
                    0.05F,
                    pointer.getPositionF().distance(anchor.getPositionF())
            );
        }
        this.calibrationGripWasDown = gripDown;
        if (!gripDown) {
            this.calibrationDragging = false;
            return;
        }
        if (!this.calibrationDragging) {
            return;
        }

        WristUiConfig config = WristUiConfig.getInstance();
        if (this.calibrationMode == WristCalibrationMode.SCALE) {
            float distance = pointer.getPositionF().distance(anchor.getPositionF());
            float nextScale = this.calibrationStartScale * distance / this.calibrationStartControllerDistance;
            WristPoseProfile current = config.pose(this.anchorController);
            current.offset(this.calibrationLocalOffset);
            config.setPose(
                    this.anchorController,
                    this.calibrationLocalOffset,
                    current.rotation(this.calibrationLocalQuaternion),
                    nextScale
            );
            updateRoomPoseInternal(config, anchor);
            return;
        }

        // Apply the other controller's rigid delta to the preview, then
        // transform the resulting room pose back into the anchor AIM space.
        WristCalibrationMath.controllerDeltaToAnchor(
                this.calibrationStartControllerRotation,
                this.calibrationStartControllerPosition,
                pointer.getMatrix(),
                pointer.getPositionF(),
                this.calibrationStartOverlayRotation,
                this.calibrationStartOverlayPosition,
                anchor.getMatrix(),
                anchor.getPositionF(),
                this.calibrationLocalOffset,
                this.calibrationLocalQuaternion,
                this.calibrationStartControllerInverse,
                this.calibrationDeltaRotation,
                this.calibrationAnchorInverse,
                this.calibrationRoomRotation,
                this.calibrationLocalRotation,
                this.calibrationStartOffsetFromController,
                this.calibrationRoomPosition
        );
        config.setPose(
                this.anchorController,
                this.calibrationLocalOffset,
                this.calibrationLocalQuaternion,
                this.calibrationStartScale
        );
        updateRoomPoseInternal(config, anchor);
    }

    private void refreshCalibrationPreviewInternal() {
        if (!this.calibrating) {
            return;
        }
        WristUiConfig config = WristUiConfig.getInstance();
        this.anchorController = ControllerType.values()[config.hand().controllerIndex()];
        ClientDataHolderVR dataHolder = ClientDataHolderVR.getInstance();
        VRData roomData = dataHolder.vrPlayer.vrdata_room_pre;
        if (roomData == null) {
            return;
        }
        VRData.VRDevicePose anchor = roomData.getController(this.anchorController.ordinal());
        if (anchor != null) {
            updateRoomPoseInternal(config, anchor);
        }
    }

    private void stopCalibrationDrag() {
        this.calibrationDragging = false;
        this.calibrationGripWasDown = false;
    }

    private static boolean calibrationGripDown(
            ClientDataHolderVR dataHolder,
            ControllerType controller
    ) {
        if (VivecraftVRMod.INSTANCE.keyRadialMenu instanceof HandedKeyBinding handed) {
            return handed.isDown(controller);
        }
        if (!VivecraftVRMod.INSTANCE.keyRadialMenu.isDown() || dataHolder.vr == null) {
            return false;
        }
        var action = dataHolder.vr.getInputAction(VivecraftVRMod.INSTANCE.keyRadialMenu);
        ControllerType origin = dataHolder.vr.getOriginControllerType(action.getLastOrigin());
        return origin == controller;
    }
}
