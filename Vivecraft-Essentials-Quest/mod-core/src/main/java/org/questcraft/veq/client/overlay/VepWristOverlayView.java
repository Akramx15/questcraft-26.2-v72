package org.questcraft.veq.client.overlay;

import net.minecraft.client.Minecraft;
import net.minecraft.client.gui.screens.Screen;
import net.minecraft.client.input.MouseButtonEvent;
import net.minecraft.client.input.MouseButtonInfo;
import net.minecraft.world.inventory.AbstractContainerMenu;
import org.jetbrains.annotations.Nullable;
import org.joml.Matrix4fc;
import org.joml.Vector2f;
import org.joml.Vector3f;
import org.joml.Vector3fc;
import org.questcraft.veq.client.wrist.WristSurfaceMath;
import org.vivecraft.client_vr.ClientDataHolderVR;
import org.vivecraft.client_vr.VRData;
import org.vivecraft.client_vr.provider.ControllerType;
import org.vivecraft.client_vr.gameplay.screenhandlers.ExternalScreenOverlayHandler;
import org.vivecraft.common.utils.MathUtils;

import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;

/** Two-controller pointer adapter for the embedded VEP inventory screen. */
public final class VepWristOverlayView implements WristOverlayView {
    private final Minecraft minecraft = Minecraft.getInstance();
    private final VepUiFeatureLayer featureLayer = new VepUiFeatureLayer();
    private final double[] pointerX = new double[ControllerType.values().length];
    private final double[] pointerY = new double[ControllerType.values().length];
    private final double[] previousX = new double[ControllerType.values().length];
    private final double[] previousY = new double[ControllerType.values().length];
    private final boolean[] focused = new boolean[ControllerType.values().length];
    private final boolean[] coordinateValid = new boolean[ControllerType.values().length];
    private final List<PointerPressOwnership<
            Screen,
            ControllerType,
            ExternalScreenOverlayHandler.PointerButton>> presses = new ArrayList<>();
    private final CarriedPointerOwnership<Screen, AbstractContainerMenu, ControllerType>
            carriedOwnership = new CarriedPointerOwnership<>();
    private final int[] hoverKey = new int[ControllerType.values().length];
    private final ExternalScreenOverlayHandler.RenderCursor[] renderCursors =
            new ExternalScreenOverlayHandler.RenderCursor[ControllerType.values().length];
    private final VepSurfaceBoundsCache<ExternalScreenOverlayHandler.SurfaceBounds>
            surfaceBoundsCache = new VepSurfaceBoundsCache<>();

    private final Vector3f controllerDirection = new Vector3f();
    private final Vector3f guiNormal = new Vector3f();
    private final Vector3f guiRight = new Vector3f();
    private final Vector3f guiUp = new Vector3f();
    private final Vector3f guiTopLeft = new Vector3f();
    private final Vector3f delta = new Vector3f();
    private final Vector3f intersection = new Vector3f();
    private final Vector2f uv = new Vector2f();

    private int scaledWidth;
    private int scaledHeight;
    private long boundsFrameIndex = Long.MIN_VALUE;
    private long boundsLayoutRevision;
    private VepScreenContent boundsContent;
    private Screen boundsScreen;

    public VepWristOverlayView() {
        Arrays.fill(this.hoverKey, -1);
        for (ControllerType controller : ControllerType.values()) {
            this.renderCursors[controller.ordinal()] = new ExternalScreenOverlayHandler.RenderCursor();
            this.presses.add(new PointerPressOwnership<>());
        }
    }

    @Override
    public @Nullable Screen screen() {
        VepScreenContent content = this.featureLayer.activeContent();
        return content == null ? null : content.screen();
    }

    @Override
    public void init(int scaledWidth, int scaledHeight) {
        for (ControllerType controller : ControllerType.values()) {
            cancel(controller, ExternalScreenOverlayHandler.PointerButton.PRIMARY);
        }
        this.scaledWidth = Math.max(1, scaledWidth);
        this.scaledHeight = Math.max(1, scaledHeight);
        this.surfaceBoundsCache.invalidate();
        this.boundsFrameIndex = Long.MIN_VALUE;
        this.boundsContent = null;
        this.boundsScreen = null;
        if (this.minecraft.player == null) {
            this.featureLayer.hardClose();
            this.carriedOwnership.clear();
            clearPointers();
            return;
        }
        this.featureLayer.initialize(this.scaledWidth, this.scaledHeight);
        refreshCarriedOwnership(this.featureLayer.activeContent());
        clearPointers();
    }

    @Override
    public boolean updatePointer(ControllerType controller,
                                 Vector3fc overlayPosition,
                                 Matrix4fc overlayRotation,
                                 float overlayScale) {
        int index = controller.ordinal();
        VepScreenContent content = this.featureLayer.activeContent();
        Screen screen = content == null ? null : content.screen();
        refreshCarriedOwnership(content);
        PointerPressOwnership<Screen, ControllerType,
                ExternalScreenOverlayHandler.PointerButton> press = press(index);
        if (press.isActive() && press.screen() != screen) {
            cancel(controller, press.button());
            setUnfocused(index);
            return false;
        }
        if (this.carriedOwnership.isActive()
                && (content == null || !this.carriedOwnership.owns(
                screen, content.menu(), controller))) {
            cancel(controller, press.button());
            setUnfocused(index);
            return false;
        }
        ClientDataHolderVR dataHolder = ClientDataHolderVR.getInstance();
        VRData roomData = dataHolder.vrPlayer.vrdata_room_pre;
        if (screen == null || !Float.isFinite(overlayScale) || overlayScale <= 0.0F) {
            cancel(controller, press.button());
            setUnfocused(index);
            return false;
        }
        if (roomData == null) {
            losePointerPose(screen, content, controller, index, press.button());
            return false;
        }
        if (dataHolder.vr == null || !dataHolder.vr.isControllerTracking(index)) {
            losePointerPose(screen, content, controller, index, press.button());
            return false;
        }

        VRData.VRDevicePose pose = roomData.getController(index);
        if (pose == null) {
            losePointerPose(screen, content, controller, index, press.button());
            return false;
        }

        Vector3fc controllerPosition = pose.getPositionF();
        // Match VRDevicePose#getDirection and Vivecraft's GUI pointer: AIM
        // forward is local -Z, not +Z.
        pose.getMatrix().transformDirection(MathUtils.BACK, this.controllerDirection).normalize();
        float aspect = (float) this.scaledHeight / (float) this.scaledWidth;
        boolean planeHit = WristSurfaceMath.rayToUv(
                controllerPosition,
                this.controllerDirection,
                overlayPosition,
                overlayRotation,
                overlayScale,
                aspect,
                this.uv,
                this.guiNormal,
                this.guiRight,
                this.guiUp,
                this.guiTopLeft,
                this.delta,
                this.intersection
        );
        if (!planeHit) {
            losePointerPose(screen, content, controller, index, press.button());
            return false;
        }

        // Keep the actual plane coordinates even after the ray leaves the
        // rendered quad. A live drag must continue with outside coordinates;
        // retaining the last in-bounds point can release into the wrong slot.
        double x = this.uv.x * this.scaledWidth;
        double y = this.uv.y * this.scaledHeight;
        this.previousX[index] = this.pointerX[index];
        this.previousY[index] = this.pointerY[index];
        this.pointerX[index] = x;
        this.pointerY[index] = y;
        this.coordinateValid[index] = Double.isFinite(x) && Double.isFinite(y);
        boolean insideQuad = WristSurfaceMath.isWithin(this.uv, 0.0F, 0.0F, 1.0F, 1.0F);
        boolean inside = insideQuad && content.containsInteractionPoint(x, y);
        this.focused[index] = inside || press.isActive();
        this.renderCursors[index].set(x, y, controller, true, inside, press.isActive());
        Screen pointerScreen = press.isActive() ? press.screen() : screen;
        pointerScreen.mouseMoved(x, y);
        if (press.isActive()) {
            pointerScreen.mouseDragged(
                    mouseEvent(index, press.button()),
                    x - this.previousX[index],
                    y - this.previousY[index]
            );
        }
        updateHoverHaptic(controller, inside ? content.hoverKey(x, y) : -1);
        return this.focused[index];
    }

    @Override
    public boolean isPointerFocused(ControllerType controller) {
        return this.focused[controller.ordinal()];
    }

    @Override
    public boolean acceptsPointerPress(
            ControllerType controller,
            ExternalScreenOverlayHandler.PointerButton button
    ) {
        if (controller == null || button == null) {
            return false;
        }
        int index = controller.ordinal();
        VepScreenContent content = this.featureLayer.activeContent();
        Screen screen = content == null ? null : content.screen();
        AbstractContainerMenu menu = content == null ? null : content.menu();
        if (screen == null || menu == null) {
            return false;
        }
        refreshCarriedOwnership(content);
        boolean carriedStackActive = this.carriedOwnership.isActive();
        boolean exactCarriedOwner = this.carriedOwnership.owns(
                screen, menu, controller);
        return WristPointerPressPolicy.accepts(
                this.focused[index],
                carriedStackActive,
                exactCarriedOwner,
                this.coordinateValid[index],
                this.pointerX[index],
                this.pointerY[index],
                this.scaledWidth,
                this.scaledHeight,
                content.containsInteractionPoint(this.pointerX[index], this.pointerY[index]),
                button
        );
    }

    @Override
    public boolean ownsInput(ControllerType controller) {
        VepScreenContent content = this.featureLayer.activeContent();
        refreshCarriedOwnership(content);
        if (content != null && this.carriedOwnership.owns(
                content.screen(), content.menu(), controller)) {
            return true;
        }
        int index = controller.ordinal();
        return this.focused[index] || press(index).isActive();
    }

    @Override
    public void clearPointer(ControllerType controller) {
        int index = controller.ordinal();
        cancel(controller, press(index).button());
        this.pointerX[index] = this.previousX[index] = -1.0D;
        this.pointerY[index] = this.previousY[index] = -1.0D;
        this.focused[index] = false;
        this.hoverKey[index] = -1;
        this.renderCursors[index].setInvalid();
    }

    @Override
    public boolean press(ControllerType controller) {
        return press(controller, ExternalScreenOverlayHandler.PointerButton.PRIMARY);
    }

    @Override
    public boolean press(ControllerType controller,
                         ExternalScreenOverlayHandler.PointerButton button) {
        int index = controller.ordinal();
        VepScreenContent content = this.featureLayer.activeContent();
        Screen screen = content == null ? null : content.screen();
        refreshCarriedOwnership(content);
        PointerPressOwnership<Screen, ControllerType,
                ExternalScreenOverlayHandler.PointerButton> press = press(index);
        if (screen == null || button == null || press.isActive()
                || !acceptsPointerPress(controller, button)) {
            return false;
        }
        boolean accepted = screen.mouseClicked(mouseEvent(index, button), false);
        if (!press.capture(screen, controller, button, accepted)) {
            return false;
        }
        // A click can synchronously replace inventory with creative content.
        // Cancel the old owner now; the new screen must never receive its up.
        if (screen() != screen) {
            completePress(press.cancel(), index);
            setUnfocused(index);
            return false;
        }
        pinCarriedOwnerAfterAcceptedPress(screen, controller);
        return true;
    }

    @Override
    public void release(ControllerType controller) {
        int index = controller.ordinal();
        release(controller, press(index).button());
    }

    @Override
    public void release(ControllerType controller,
                        ExternalScreenOverlayHandler.PointerButton button) {
        int index = controller.ordinal();
        PointerPressOwnership<Screen, ControllerType,
                ExternalScreenOverlayHandler.PointerButton> press = press(index);
        completePress(press.finish(
                screen(),
                controller,
                this.coordinateValid[index]
                        && Double.isFinite(pointerX[index])
                        && Double.isFinite(pointerY[index])
        ), index);
        VepScreenContent content = this.featureLayer.activeContent();
        this.focused[index] = content != null
                && content.containsInteractionPoint(pointerX[index], pointerY[index]);
    }

    @Override
    public void cancel(ControllerType controller,
                       ExternalScreenOverlayHandler.PointerButton button) {
        int index = controller.ordinal();
        completePress(press(index).cancel(), index);
        this.focused[index] = false;
    }

    @Override
    public void scroll(ControllerType controller, double amount) {
        int index = controller.ordinal();
        Screen screen = screen();
        if (screen != null && this.focused[index] && Double.isFinite(amount)) {
            screen.mouseScrolled(this.pointerX[index], this.pointerY[index], 0.0D, amount);
        }
    }

    @Override
    public ExternalScreenOverlayHandler.RenderCursor renderCursor() {
        // A pressed pointer owns rendering through drag/release even after its
        // ray leaves the panel. Otherwise prefer the currently focused hand.
        for (ControllerType controller : ControllerType.values()) {
            int index = controller.ordinal();
            if (press(index).isActive()) {
                return this.renderCursors[index];
            }
        }
        for (ControllerType controller : ControllerType.values()) {
            int index = controller.ordinal();
            if (focused[index]) {
                return this.renderCursors[index];
            }
        }
        ControllerType carriedController = carriedController();
        if (carriedController != null) {
            ExternalScreenOverlayHandler.RenderCursor cursor =
                    this.renderCursors[carriedController.ordinal()];
            if (cursor.valid()) {
                return cursor;
            }
        }
        return ExternalScreenOverlayHandler.RenderCursor.invalid();
    }

    @Override
    public ExternalScreenOverlayHandler.RenderCursor renderCursor(ControllerType controller) {
        return controller == null
                ? ExternalScreenOverlayHandler.RenderCursor.invalid()
                : this.renderCursors[controller.ordinal()];
    }

    @Override
    public int hoverKey(ControllerType controller) {
        return controller == null ? -1 : this.hoverKey[controller.ordinal()];
    }

    @Override
    public ExternalScreenOverlayHandler.SurfaceBounds bounds() {
        VepScreenContent content = this.featureLayer.activeContent();
        if (content == null) {
            this.surfaceBoundsCache.invalidate();
            this.boundsFrameIndex = Long.MIN_VALUE;
            this.boundsContent = null;
            this.boundsScreen = null;
            return ExternalScreenOverlayHandler.SurfaceBounds.full();
        }
        Screen screen = content.screen();
        long frameIndex = ClientDataHolderVR.getInstance().frameIndex;
        if (frameIndex != this.boundsFrameIndex
                || content != this.boundsContent
                || screen != this.boundsScreen) {
            this.boundsLayoutRevision = content.visualLayoutRevision();
            this.boundsFrameIndex = frameIndex;
            this.boundsContent = content;
            this.boundsScreen = screen;
        }
        long layoutRevision = this.boundsLayoutRevision;
        if (this.surfaceBoundsCache.matches(
                content,
                screen,
                this.scaledWidth,
                this.scaledHeight,
                layoutRevision
        )) {
            return this.surfaceBoundsCache.value();
        }
        var bounds = content.visualBounds();
        int left = Math.max(0, bounds.x());
        int top = Math.max(0, bounds.y());
        int right = Math.min(this.scaledWidth, bounds.x() + bounds.width());
        int bottom = Math.min(this.scaledHeight, bounds.y() + bounds.height());
        ExternalScreenOverlayHandler.SurfaceBounds resolved;
        if (right <= left || bottom <= top) {
            resolved = ExternalScreenOverlayHandler.SurfaceBounds.full();
        } else {
            resolved = new ExternalScreenOverlayHandler.SurfaceBounds(
                    left,
                    top,
                    right - left,
                    bottom - top
            );
        }
        this.surfaceBoundsCache.store(
                content,
                screen,
                this.scaledWidth,
                this.scaledHeight,
                layoutRevision,
                resolved
        );
        return resolved;
    }

    public VepUiFeatureLayer featureLayer() {
        return this.featureLayer;
    }

    ControllerType carriedController() {
        VepScreenContent content = this.featureLayer.activeContent();
        refreshCarriedOwnership(content);
        return this.carriedOwnership.controller();
    }

    ControllerType interactionController() {
        for (PointerPressOwnership<Screen, ControllerType,
                ExternalScreenOverlayHandler.PointerButton> press : this.presses) {
            if (press.isActive()) {
                return press.controller();
            }
        }
        return carriedController();
    }

    @Override
    public boolean canHide() {
        VepScreenContent content = this.featureLayer.activeContent();
        if (content == null) {
            return true;
        }
        for (PointerPressOwnership<Screen, ControllerType,
                ExternalScreenOverlayHandler.PointerButton> press : this.presses) {
            if (press.isActive()) {
                return false;
            }
        }
        return content.canSoftHide();
    }

    @Override
    public void onShown() {
        clearPointers();
    }

    @Override
    public void onHidden(boolean hardClose) {
        for (ControllerType controller : ControllerType.values()) {
            cancel(controller, press(controller.ordinal()).button());
        }
        if (hardClose) {
            this.featureLayer.hardClose();
            this.carriedOwnership.clear();
            this.surfaceBoundsCache.invalidate();
        } else {
            refreshCarriedOwnership(this.featureLayer.activeContent());
        }
        clearPointers();
    }

    private MouseButtonEvent mouseEvent(int index,
                                        ExternalScreenOverlayHandler.PointerButton button) {
        return new MouseButtonEvent(
                pointerX[index],
                pointerY[index],
                new MouseButtonInfo(button.mouseButton(), 0)
        );
    }

    private void updateHoverHaptic(ControllerType controller, int nextHoverKey) {
        int index = controller.ordinal();
        if (nextHoverKey >= 0 && nextHoverKey != this.hoverKey[index]) {
            ClientDataHolderVR.getInstance().vr.triggerHapticPulse(
                    controller,
                    0.0003F,
                    160.0F,
                    1.0F
            );
        }
        this.hoverKey[index] = nextHoverKey;
    }

    private void setUnfocused(int index) {
        this.coordinateValid[index] = false;
        this.focused[index] = false;
        this.renderCursors[index].setInvalid();
        this.hoverKey[index] = -1;
    }

    /**
     * Keeps only the last visual coordinate while a carried stack owns this
     * controller. Input remains unfocused and stale coordinates can never be
     * released into a slot; the compositor clamps the icon to the panel edge.
     */
    private boolean retainCarriedRenderCursor(
            Screen screen,
            VepScreenContent content,
            ControllerType controller,
            int index
    ) {
        refreshCarriedOwnership(content);
        ExternalScreenOverlayHandler.RenderCursor cursor = this.renderCursors[index];
        if (content == null || screen == null || !cursor.valid()
                || !this.carriedOwnership.owns(
                screen, content.menu(), controller)) {
            return false;
        }
        this.coordinateValid[index] = false;
        this.focused[index] = false;
        this.hoverKey[index] = -1;
        cursor.set(cursor.x(), cursor.y(), controller, true, false, false);
        return true;
    }

    private void losePointerPose(
            Screen screen,
            VepScreenContent content,
            ControllerType controller,
            int index,
            ExternalScreenOverlayHandler.PointerButton button
    ) {
        cancel(controller, button);
        if (!retainCarriedRenderCursor(screen, content, controller, index)) {
            setUnfocused(index);
        }
    }

    private void clearPointers() {
        for (ControllerType controller : ControllerType.values()) {
            cancel(controller, press(controller.ordinal()).button());
        }
        Arrays.fill(this.pointerX, -1.0D);
        Arrays.fill(this.pointerY, -1.0D);
        Arrays.fill(this.previousX, -1.0D);
        Arrays.fill(this.previousY, -1.0D);
        Arrays.fill(this.focused, false);
        Arrays.fill(this.coordinateValid, false);
        Arrays.fill(this.hoverKey, -1);
        for (ExternalScreenOverlayHandler.RenderCursor cursor : this.renderCursors) {
            cursor.setInvalid();
        }
    }

    private PointerPressOwnership<Screen, ControllerType,
            ExternalScreenOverlayHandler.PointerButton> press(int index) {
        return this.presses.get(index);
    }

    private void completePress(
            PointerPressOwnership.Completion<Screen, ControllerType,
                    ExternalScreenOverlayHandler.PointerButton> completion,
            int index
    ) {
        if (completion.disposition() == PointerPressOwnership.Disposition.RELEASE) {
            SafeScreenPointerRelease.release(
                    completion.screen(),
                    completion.button(),
                    this.pointerX[index],
                    this.pointerY[index]
            );
        } else if (completion.disposition() == PointerPressOwnership.Disposition.CANCEL) {
            SafeScreenPointerRelease.cancel(completion.screen(), completion.button());
        }
        updateCarriedOwnership(completion);
        ExternalScreenOverlayHandler.RenderCursor cursor = this.renderCursors[index];
        if (cursor.valid()) {
            cursor.set(
                    cursor.x(),
                    cursor.y(),
                    cursor.controller(),
                    true,
                    cursor.focused(),
                    false
            );
        }
    }

    private void updateCarriedOwnership(
            PointerPressOwnership.Completion<Screen, ControllerType,
                    ExternalScreenOverlayHandler.PointerButton> completion
    ) {
        VepScreenContent content = this.featureLayer.activeContent();
        refreshCarriedOwnership(content);
        if (completion.disposition() == PointerPressOwnership.Disposition.NONE
                || content == null
                || completion.screen() != content.screen()) {
            return;
        }
        AbstractContainerMenu menu = content.menu();
        if (menu != null) {
            this.carriedOwnership.retainOrCapture(
                    content.screen(),
                    menu,
                    completion.controller(),
                    !menu.getCarried().isEmpty()
            );
        }
    }

    /**
     * Mouse down may synchronously pick up or drop Minecraft's carried stack.
     * Reconcile before returning to the central per-controller dispatcher so
     * the next controller in the same input frame cannot steal the cursor.
     */
    private void pinCarriedOwnerAfterAcceptedPress(
            Screen clickedScreen,
            ControllerType controller
    ) {
        VepScreenContent content = this.featureLayer.activeContent();
        if (content == null || content.screen() != clickedScreen) {
            refreshCarriedOwnership(content);
            return;
        }
        AbstractContainerMenu menu = content.menu();
        if (menu == null) {
            refreshCarriedOwnership(content);
            return;
        }
        this.carriedOwnership.pinAfterAcceptedPress(
                clickedScreen,
                menu,
                controller,
                !menu.getCarried().isEmpty()
        );
    }

    private void refreshCarriedOwnership(VepScreenContent content) {
        Screen currentScreen = content == null ? null : content.screen();
        AbstractContainerMenu currentMenu = content == null ? null : content.menu();
        this.carriedOwnership.refresh(
                currentScreen,
                currentMenu,
                currentMenu != null && !currentMenu.getCarried().isEmpty()
        );
    }
}
