package org.questcraft.veq.client.overlay;

import com.mojang.blaze3d.pipeline.RenderTarget;
import net.minecraft.client.Minecraft;
import net.minecraft.client.gui.screens.Screen;
import net.minecraft.client.gui.screens.inventory.AbstractContainerScreen;
import net.minecraft.client.gui.screens.inventory.CreativeModeInventoryScreen;
import net.minecraft.client.gui.screens.inventory.InventoryScreen;
import net.minecraft.client.input.MouseButtonEvent;
import net.minecraft.client.input.MouseButtonInfo;
import net.minecraft.world.inventory.AbstractContainerMenu;
import org.jetbrains.annotations.Nullable;
import org.joml.Matrix4f;
import org.joml.Matrix4fc;
import org.joml.Vector2f;
import org.joml.Vector3f;
import org.joml.Vector3fc;
import org.questcraft.veq.VivecraftEssentialsQuest;
import org.questcraft.veq.client.config.VepFeatureConfig;
import org.vivecraft.client_vr.ClientDataHolderVR;
import org.vivecraft.client_vr.VRData;
import org.vivecraft.client_vr.VRState;
import org.vivecraft.client_vr.gameplay.screenhandlers.ExternalScreenOverlayHandler;
import org.vivecraft.client_vr.gameplay.screenhandlers.GuiHandler;
import org.vivecraft.client_vr.provider.ControllerType;
import org.vivecraft.client_vr.render.helpers.RenderHelper;

import java.util.ArrayList;
import java.util.List;

/**
 * Claims an eligible native container screen without replacing or re-initializing it.
 * Minecraft remains the sole owner of Screen/menu lifecycle; VEQ only supplies an
 * independent render target and VR pointer surface while both controllers track.
 */
public final class VepContextualContainerRuntime implements AutoCloseable {
    private static final String CLAIM_OWNER = "vivecraft_essentials_quest:contextual_container";

    private final Minecraft minecraft = Minecraft.getInstance();
    private final VepUiFeatureLayer featureLayer;
    private final ContextualSurface surface = new ContextualSurface();
    private final ExternalScreenOverlayHandler.OverlayHandle surfaceHandle;

    private @Nullable AbstractContainerScreen<?> activeScreen;
    private @Nullable ExternalScreenOverlayHandler.GlobalScreenClaim claim;

    public VepContextualContainerRuntime(VepUiFeatureLayer featureLayer) {
        this.featureLayer = java.util.Objects.requireNonNull(featureLayer, "featureLayer");
        this.surfaceHandle = ExternalScreenOverlayHandler.registerSurface(surface);
    }

    /** Called from the client tick after vanilla has completed Gui#setScreen. */
    public void tick() {
        Screen current = minecraft.gui == null ? null : minecraft.gui.screen();
        if (activeScreen != null) {
            if (current != activeScreen || claim == null || !claim.isActive()) {
                releaseClaim();
            } else if (!eligible(activeScreen)) {
                boolean tracked = controllersTracked();
                if (ContextualTrackingClaimPolicy.retain(
                        tracked,
                        VRState.VR_RUNNING
                                && ClientDataHolderVR.getInstance().vr != null
                                && eligible(activeScreen, true),
                        surface.hasCarriedOwner(activeScreen))) {
                    return;
                }
                // Releasing ownership restores the ordinary native GUI plane.
                // It intentionally does not close the screen or its menu.
                releaseClaim();
            } else {
                return;
            }
        }

        if (current instanceof AbstractContainerScreen<?> container && eligible(container)) {
            capture(container);
        }
    }

    public boolean owns(@Nullable Screen screen) {
        return surface.isCurrentClaimedScreen(screen);
    }

    private boolean eligible(AbstractContainerScreen<?> screen) {
        return eligible(screen, controllersTracked());
    }

    private boolean controllersTracked() {
        return VRState.VR_RUNNING
                && ClientDataHolderVR.getInstance().vr != null
                && ClientDataHolderVR.getInstance().vr.isControllerTracking(0)
                && ClientDataHolderVR.getInstance().vr.isControllerTracking(1);
    }

    private boolean eligible(AbstractContainerScreen<?> screen, boolean tracked) {
        var player = minecraft.player;
        return ContextualContainerPolicy.shouldClaim(
                VepFeatureConfig.getInstance().contextualContainers(),
                minecraft.level != null,
                player != null && player.isAlive(),
                tracked,
                true,
                screen instanceof InventoryScreen,
                screen instanceof CreativeModeInventoryScreen,
                player != null && player.containerMenu == screen.getMenu(),
                player != null && player.inventoryMenu == screen.getMenu()
        ) && ContextualCancelCapability.isSafe(screen);
    }

    private void capture(AbstractContainerScreen<?> screen) {
        ExternalScreenOverlayHandler.GlobalScreenClaim next;
        try {
            next = ExternalScreenOverlayHandler.claimGlobalScreen(
                    CLAIM_OWNER,
                    screen,
                    this::claimLost
            );
        } catch (IllegalArgumentException | IllegalStateException exception) {
            VivecraftEssentialsQuest.LOGGER.debug(
                    "Could not claim contextual container screen {}: {}",
                    screen.getClass().getName(),
                    exception.getMessage()
            );
            return;
        }

        activeScreen = screen;
        claim = next;
        featureLayer.showContextualContainer(new VepContextualContainerContent(
                screen,
                new org.questcraft.veq.client.gui.VepWristInventoryScreen.Bounds(
                        0,
                        0,
                        Math.max(1, screen.width),
                        Math.max(1, screen.height)
                ),
                null
        ));
        surface.clearForTeardown();
    }

    private void claimLost(Screen screen,
                           ExternalScreenOverlayHandler.GlobalScreenLossReason reason) {
        if (screen != activeScreen) {
            return;
        }
        // Release any in-flight native drag while the wrapped Screen is still
        // reachable. Clearing the feature-layer reference first would leave
        // the container with a latched mouse button after tracking loss.
        surface.clearForTeardown();
        activeScreen = null;
        claim = null;
        featureLayer.clearContextualContainer(false);
    }

    private void releaseClaim() {
        ExternalScreenOverlayHandler.GlobalScreenClaim oldClaim = claim;
        // See claimLost: native Screen owns drag/carried-item semantics, so it
        // must receive the matching release before we drop our UI reference.
        surface.clearForTeardown();
        activeScreen = null;
        claim = null;
        featureLayer.clearContextualContainer(false);
        if (oldClaim != null && oldClaim.isActive()) {
            oldClaim.close();
        }
    }

    @Override
    public void close() {
        releaseClaim();
        surfaceHandle.close();
    }

    private final class ContextualSurface implements ExternalScreenOverlayHandler.OverlaySurface {
        private final ExternalScreenOverlayHandler.RenderCursor[] cursors =
                new ExternalScreenOverlayHandler.RenderCursor[ControllerType.values().length];
        private final List<PointerPressOwnership<
                Screen,
                ControllerType,
                ExternalScreenOverlayHandler.PointerButton>> presses = new ArrayList<>();
        private final CarriedPointerOwnership<Screen, AbstractContainerMenu, ControllerType>
                carriedOwnership = new CarriedPointerOwnership<>();
        private final Vector3f fallbackPosition = new Vector3f();
        private final Matrix4f fallbackRotation = new Matrix4f();

        private ContextualSurface() {
            for (ControllerType controller : ControllerType.values()) {
                cursors[controller.ordinal()] = new ExternalScreenOverlayHandler.RenderCursor();
                presses.add(new PointerPressOwnership<>());
            }
        }

        @Override
        public String id() {
            return VepContextualContainerContent.SURFACE_ID;
        }

        @Override
        public String name() {
            return "Vivecraft Essentials Quest Contextual Container";
        }

        @Override
        public @Nullable Screen screen() {
            VepContextualContainerContent content = featureLayer.contextualContainer();
            return content == null ? null : content.screen();
        }

        @Override
        public boolean isShowing() {
            return isCurrentClaimedScreen(activeScreen)
                    && GuiHandler.GUI_POS_ROOM != null
                    && GuiHandler.GUI_ROTATION_ROOM != null;
        }

        @Override
        public Vector3fc roomPosition() {
            return GuiHandler.GUI_POS_ROOM == null ? fallbackPosition : GuiHandler.GUI_POS_ROOM;
        }

        @Override
        public Matrix4fc roomRotation() {
            return GuiHandler.GUI_ROTATION_ROOM == null ? fallbackRotation : GuiHandler.GUI_ROTATION_ROOM;
        }

        @Override
        public float scale() {
            return Float.isFinite(GuiHandler.GUI_SCALE) && GuiHandler.GUI_SCALE > 0.0F
                    ? GuiHandler.GUI_SCALE
                    : 1.0F;
        }

        @Override
        public int priority() {
            return 70;
        }

        @Override
        public int renderWidth() {
            return GuiHandler.GUI_WIDTH;
        }

        @Override
        public int renderHeight() {
            return GuiHandler.GUI_HEIGHT;
        }

        @Override
        public int scaledWidth() {
            return activeScreen == null ? 1 : Math.max(1, activeScreen.width);
        }

        @Override
        public int scaledHeight() {
            return activeScreen == null ? 1 : Math.max(1, activeScreen.height);
        }

        @Override
        public void resize(int scaledWidth, int scaledHeight) {
            // Minecraft owns native Screen initialization and dimensions.
        }

        @Override
        public void renderSurface(
                RenderTarget target,
                ExternalScreenOverlayHandler.RenderCursor cursor
        ) {
            AbstractContainerScreen<?> screen = activeScreen;
            if (target == null || !isCurrentClaimedScreen(screen)) {
                return;
            }
            int mouseX = cursor != null && cursor.valid()
                    ? VepSurfacePointerRenderer.screenMouseCoordinate(cursor.x())
                    : -10_000;
            int mouseY = cursor != null && cursor.valid()
                    ? VepSurfacePointerRenderer.screenMouseCoordinate(cursor.y())
                    : -10_000;
            ContextualContainerRenderPass.withCarriedDeferred(
                    screen,
                    () -> RenderHelper.drawScreen(screen, true, mouseX, mouseY)
            );
        }

        @Override
        public void renderCarriedItem(
                RenderTarget target,
                ExternalScreenOverlayHandler.RenderCursor cursor
        ) {
            AbstractContainerScreen<?> screen = activeScreen;
            if (!isCurrentClaimedScreen(screen)) {
                return;
            }
            // This callback is the final pass of this exact contextual
            // surface. Draw '+' from its selected RenderCursor, then let the
            // native screen put its carried stack in the following stratum.
            VepSurfacePointerRenderer.renderPointerWithCarriedAbove(
                    target,
                    screen,
                    cursor,
                    scaledWidth(),
                    scaledHeight(),
                    bounds()
            );
        }

        @Override
        public ExternalScreenOverlayHandler.RenderCursor cursor(ControllerType controller) {
            if (controller == null) {
                return ExternalScreenOverlayHandler.RenderCursor.invalid();
            }
            int index = controller.ordinal();
            PointerPressOwnership<Screen, ControllerType,
                    ExternalScreenOverlayHandler.PointerButton> press = press(index);
            if (!isCurrentClaimedScreen(press.isActive() ? press.screen() : activeScreen)) {
                completePress(press.cancel(), cursors[index]);
                refreshCarriedOwnership();
                return cursors[index].setInvalid();
            }
            refreshCarriedOwnership();
            if (this.carriedOwnership.isActive()
                    && !this.carriedOwnership.owns(
                    activeScreen, activeScreen.getMenu(), controller)) {
                completePress(press.cancel(), cursors[index]);
                return cursors[index].setInvalid();
            }
            if (GuiHandler.GUI_POS_ROOM == null || GuiHandler.GUI_ROTATION_ROOM == null) {
                completePress(press.cancel(), cursors[index]);
                return cursors[index].setInvalid();
            }
            ClientDataHolderVR dataHolder = ClientDataHolderVR.getInstance();
            VRData room = dataHolder.vrPlayer.vrdata_room_pre;
            if (dataHolder.vr == null || room == null || !dataHolder.vr.isControllerTracking(index)) {
                completePress(press.cancel(), cursors[index]);
                return cursors[index].setInvalid();
            }
            VRData.VRDevicePose pose = room.getController(index);
            if (pose == null) {
                completePress(press.cancel(), cursors[index]);
                return cursors[index].setInvalid();
            }

            Vector2f uv = GuiHandler.getTexCoordsForCursor(
                    GuiHandler.GUI_POS_ROOM,
                    GuiHandler.GUI_ROTATION_ROOM,
                    scale(),
                    pose
            );
            boolean finite = Float.isFinite(uv.x) && Float.isFinite(uv.y);
            boolean focused = VepSurfacePointerRenderer.isInsideUnitUv(uv.x, uv.y);
            if (!finite) {
                completePress(press.cancel(), cursors[index]);
                return cursors[index].setInvalid();
            }
            boolean carried = this.carriedOwnership.owns(
                    activeScreen, activeScreen.getMenu(), controller);
            if (!focused && !press.isActive() && !carried) {
                return cursors[index].setInvalid();
            }
            return cursors[index].set(
                    (double) uv.x * scaledWidth(),
                    (double) uv.y * scaledHeight(),
                    controller,
                    true,
                    focused,
                    press.isActive()
            );
        }

        @Override
        public ExternalScreenOverlayHandler.RenderCursor renderCursor() {
            for (ControllerType controller : ControllerType.values()) {
                if (press(controller.ordinal()).isActive()) {
                    ExternalScreenOverlayHandler.RenderCursor cursor = cursor(controller);
                    if (cursor.valid()) {
                        return cursor;
                    }
                }
            }
            refreshCarriedOwnership();
            ControllerType carriedController = this.carriedOwnership.controller();
            if (carriedController != null) {
                ExternalScreenOverlayHandler.RenderCursor cursor = cursor(carriedController);
                if (cursor.valid()) {
                    return cursor;
                }
            }
            for (ControllerType controller : ControllerType.values()) {
                ExternalScreenOverlayHandler.RenderCursor cursor = cursor(controller);
                if (cursor.valid() && cursor.focused()) {
                    return cursor;
                }
            }
            return ExternalScreenOverlayHandler.RenderCursor.invalid();
        }

        @Override
        public boolean isUsingController(ControllerType controller) {
            if (controller == null) {
                return false;
            }
            refreshCarriedOwnership();
            if (activeScreen != null && this.carriedOwnership.owns(
                    activeScreen, activeScreen.getMenu(), controller)) {
                return true;
            }
            ExternalScreenOverlayHandler.RenderCursor cursor = cursor(controller);
            return press(controller.ordinal()).isActive() || (cursor.valid() && cursor.focused());
        }

        @Override
        public boolean handlesPointerEvents() {
            return true;
        }

        @Override
        public void pointerMoved(ControllerType controller,
                                 ExternalScreenOverlayHandler.RenderCursor cursor,
                                 double deltaX,
                                 double deltaY) {
            PointerPressOwnership<Screen, ControllerType,
                    ExternalScreenOverlayHandler.PointerButton> press = press(controller.ordinal());
            Screen pointerScreen = press.isActive() ? press.screen() : activeScreen;
            if (!isCurrentClaimedScreen(pointerScreen)) {
                completePress(press.cancel(), cursor);
                return;
            }
            refreshCarriedOwnership();
            if (this.carriedOwnership.isActive()
                    && !this.carriedOwnership.owns(
                    pointerScreen,
                    ((AbstractContainerScreen<?>) pointerScreen).getMenu(),
                    controller)) {
                return;
            }
            if (pointerScreen != null) {
                pointerScreen.mouseMoved(cursor.x(), cursor.y());
            }
        }

        @Override
        public void pointerPressed(ControllerType controller,
                                   ExternalScreenOverlayHandler.RenderCursor cursor,
                                   ExternalScreenOverlayHandler.PointerButton button) {
            AbstractContainerScreen<?> screen = activeScreen;
            if (!isCurrentClaimedScreen(screen)) {
                return;
            }
            refreshCarriedOwnership();
            int index = controller.ordinal();
            PointerPressOwnership<Screen, ControllerType,
                    ExternalScreenOverlayHandler.PointerButton> press = press(index);
            if (!VepSurfacePointerRenderer.canReceiveInput(
                    cursor, scaledWidth(), scaledHeight())
                    || press.isActive() || anyPressedExcept(index)
                    || (this.carriedOwnership.isActive()
                    && !this.carriedOwnership.owns(
                    screen, activeScreen.getMenu(), controller))) {
                return;
            }
            boolean accepted = screen.mouseClicked(mouseEvent(cursor, button), false);
            if (press.capture(screen, controller, button, accepted)
                    && !isCurrentClaimedScreen(screen)) {
                completePress(press.cancel(), cursor);
            }
        }

        @Override
        public void pointerDragged(ControllerType controller,
                                   ExternalScreenOverlayHandler.RenderCursor cursor,
                                   ExternalScreenOverlayHandler.PointerButton button,
                                   double deltaX,
                                   double deltaY) {
            int index = controller.ordinal();
            PointerPressOwnership<Screen, ControllerType,
                    ExternalScreenOverlayHandler.PointerButton> press = press(index);
            if (press.isActive()) {
                if (!isCurrentClaimedScreen(press.screen())) {
                    completePress(press.cancel(), cursor);
                    return;
                }
                press.screen().mouseDragged(mouseEvent(cursor, press.button()), deltaX, deltaY);
            }
        }

        @Override
        public void pointerReleased(ControllerType controller,
                                    ExternalScreenOverlayHandler.RenderCursor cursor,
                                    ExternalScreenOverlayHandler.PointerButton button) {
            int index = controller.ordinal();
            Screen current = isCurrentClaimedScreen(activeScreen) ? activeScreen : null;
            completePress(press(index).finish(
                    current,
                    controller,
                    cursor.valid() && Double.isFinite(cursor.x()) && Double.isFinite(cursor.y())
            ), cursor);
        }

        @Override
        public void pointerCancelled(ControllerType controller,
                                     ExternalScreenOverlayHandler.PointerButton button) {
            int index = controller.ordinal();
            completePress(press(index).cancel(), cursors[index]);
            cursors[index].setInvalid();
        }

        @Override
        public void pointerScrolled(ControllerType controller,
                                    ExternalScreenOverlayHandler.RenderCursor cursor,
                                    double amount) {
            AbstractContainerScreen<?> screen = activeScreen;
            refreshCarriedOwnership();
            boolean ownsCarried = screen != null && this.carriedOwnership.owns(
                    screen, screen.getMenu(), controller);
            if (isCurrentClaimedScreen(screen)
                    && (!this.carriedOwnership.isActive() || ownsCarried)
                    && VepSurfacePointerRenderer.canReceiveInput(
                    cursor, scaledWidth(), scaledHeight())
                    && Double.isFinite(amount)) {
                screen.mouseScrolled(cursor.x(), cursor.y(), 0.0D, amount);
            }
        }

        private boolean anyPressedExcept(int index) {
            for (int other = 0; other < presses.size(); other++) {
                if (other != index && press(other).isActive()) {
                    return true;
                }
            }
            return false;
        }

        private MouseButtonEvent mouseEvent(ExternalScreenOverlayHandler.RenderCursor cursor,
                                            ExternalScreenOverlayHandler.PointerButton button) {
            return new MouseButtonEvent(
                    cursor.x(),
                    cursor.y(),
                    new MouseButtonInfo(button.mouseButton(), 0)
            );
        }

        private void clearForTeardown() {
            for (ControllerType controller : ControllerType.values()) {
                int index = controller.ordinal();
                completePress(press(index).cancel(), cursors[index]);
                cursors[index].setInvalid();
            }
            this.carriedOwnership.clear();
        }

        private PointerPressOwnership<Screen, ControllerType,
                ExternalScreenOverlayHandler.PointerButton> press(int index) {
            return presses.get(index);
        }

        private void completePress(
                PointerPressOwnership.Completion<Screen, ControllerType,
                        ExternalScreenOverlayHandler.PointerButton> completion,
                ExternalScreenOverlayHandler.RenderCursor cursor
        ) {
            if (completion.disposition() == PointerPressOwnership.Disposition.RELEASE) {
                SafeScreenPointerRelease.release(
                        completion.screen(),
                        completion.button(),
                        cursor.x(),
                        cursor.y()
                );
            } else if (completion.disposition() == PointerPressOwnership.Disposition.CANCEL) {
                SafeScreenPointerRelease.cancel(completion.screen(), completion.button());
            }
            updateCarriedOwnership(completion);
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

        private boolean isCurrentClaimedScreen(Screen captured) {
            Screen featureScreen = screen();
            Screen globalScreen = minecraft.gui == null ? null : minecraft.gui.screen();
            return ExactScreenClaim.isCurrent(
                    captured,
                    activeScreen,
                    featureScreen,
                    globalScreen,
                    claim != null && claim.isActive()
            );
        }

        private void updateCarriedOwnership(
                PointerPressOwnership.Completion<Screen, ControllerType,
                        ExternalScreenOverlayHandler.PointerButton> completion
        ) {
            refreshCarriedOwnership();
            if (completion.disposition() == PointerPressOwnership.Disposition.NONE
                    || !isCurrentClaimedScreen(completion.screen())
                    || !(completion.screen() instanceof AbstractContainerScreen<?> container)) {
                return;
            }
            this.carriedOwnership.retainOrCapture(
                    completion.screen(),
                    container.getMenu(),
                    completion.controller(),
                    !container.getMenu().getCarried().isEmpty()
            );
        }

        private void refreshCarriedOwnership() {
            AbstractContainerScreen<?> current = isCurrentClaimedScreen(activeScreen)
                    ? activeScreen
                    : null;
            AbstractContainerMenu menu = current == null ? null : current.getMenu();
            this.carriedOwnership.refresh(
                    current,
                    menu,
                    menu != null && !menu.getCarried().isEmpty()
            );
        }

        private boolean hasCarriedOwner(AbstractContainerScreen<?> screen) {
            refreshCarriedOwnership();
            if (screen != null
                    && !this.carriedOwnership.isActive()
                    && !screen.getMenu().getCarried().isEmpty()) {
                for (PointerPressOwnership<Screen, ControllerType,
                        ExternalScreenOverlayHandler.PointerButton> press : this.presses) {
                    if (press.isActive() && press.screen() == screen) {
                        this.carriedOwnership.retainOrCapture(
                                screen,
                                screen.getMenu(),
                                press.controller(),
                                true
                        );
                        break;
                    }
                }
            }
            return screen != null
                    && this.carriedOwnership.isActive()
                    && this.carriedOwnership.screen() == screen
                    && this.carriedOwnership.menu() == screen.getMenu();
        }
    }
}
