package org.vivecraft.client_vr.gameplay.screenhandlers;

import com.mojang.blaze3d.pipeline.RenderTarget;
import com.mojang.blaze3d.systems.RenderSystem;
import net.minecraft.client.KeyMapping;
import net.minecraft.client.Minecraft;
import net.minecraft.client.gui.screens.Screen;
import net.minecraft.world.item.ItemStack;
import org.joml.Matrix4fc;
import org.joml.Vector3fc;
import org.vivecraft.client_vr.ClientDataHolderVR;
import org.vivecraft.client_vr.VRTextureTarget;
import org.vivecraft.client_vr.provider.ControllerType;
import org.vivecraft.client_vr.provider.openvr_lwjgl.VRInputAction;
import org.vivecraft.client_vr.render.helpers.ExternalOverlayRenderPolicy;
import org.vivecraft.client_vr.render.helpers.RenderHelper;
import org.vivecraft.client_vr.render.helpers.ShaderHelper;
import org.vivecraft.client_vr.render.helpers.SurfaceGuiMetrics;
import org.vivecraft.client_vr.render.helpers.graphics.GraphicsHelper;
import org.vivecraft.client_vr.render.renderstates.ScreenRenderState;
import org.vivecraft.common.utils.MathUtils;

import javax.annotation.Nullable;
import java.util.ArrayList;
import java.util.Comparator;
import java.util.EnumMap;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.function.Consumer;

/**
 * Registry and lifecycle owner for independently rendered client add-on
 * surfaces.
 *
 * <p>Every surface owns its content, pose and pointer math. Vivecraft owns a
 * presentation target per registered surface (plus an optional retained
 * content target), resolves per-controller focus by priority, records each
 * visible surface exactly once before the stereo world passes, and reuses the
 * presentation texture in both eyes.</p>
 *
 * <p>This is deliberately an internal integration point rather than part of
 * the public Vivecraft mod API. The legacy single-overlay methods remain so a
 * source-compatible add-on can migrate one surface at a time.</p>
 */
public final class ExternalScreenOverlayHandler {
    private static final Comparator<OverlayHandle> RENDER_ORDER = Comparator
        .comparingInt((OverlayHandle handle) -> handle.surface.priority())
        .thenComparingLong(OverlayHandle::registrationOrder);

    private static final Map<String, OverlayHandle> SURFACES = new LinkedHashMap<>();
    private static final List<OverlayHandle> SORTED_SURFACES = new ArrayList<>();
    private static final EnumMap<ControllerType, OverlayHandle> FOCUSED_SURFACES =
        new EnumMap<>(ControllerType.class);
    private static final EnumMap<ControllerType, OverlayHandle> PRESSED_SURFACES =
        new EnumMap<>(ControllerType.class);
    private static final EnumMap<ControllerType, PointerButton> PRESSED_BUTTONS =
        new EnumMap<>(ControllerType.class);
    private static final EnumMap<ControllerType, PointerSource> PRESSED_SOURCES =
        new EnumMap<>(ControllerType.class);
    private static final ExternalPointerFreshPressGate SECONDARY_PRESS_GATE =
        new ExternalPointerFreshPressGate();

    private static long nextRegistrationOrder;
    private static boolean renderOrderDirty;
    @Nullable
    private static GlobalScreenClaim globalScreenClaim;
    private static Consumer<Runnable> globalScreenCallbackDispatcher =
        ExternalScreenOverlayHandler::dispatchOnClientThread;

    private ExternalScreenOverlayHandler() {
    }

    /**
     * Claims the current global screen for rendering and pointer ownership by
     * an external surface. The screen remains installed in {@link Minecraft}'s
     * {@code Gui}; this facility never closes, replaces, resizes or re-inits it.
     */
    public static GlobalScreenClaim claimGlobalScreen(String ownerId, Screen screen) {
        return claimGlobalScreen(ownerId, screen, null);
    }

    /** Same as {@link #claimGlobalScreen(String, Screen)}, with a lifecycle notification. */
    public static synchronized GlobalScreenClaim claimGlobalScreen(
        String ownerId, Screen screen, @Nullable GlobalScreenClaimListener listener)
    {
        Minecraft minecraft = Minecraft.getInstance();
        Screen currentScreen = minecraft == null || minecraft.gui == null ? null : minecraft.gui.screen();
        return claimGlobalScreenAgainst(ownerId, screen, currentScreen, listener);
    }

    /** Returns whether this exact screen identity owns the active claim. */
    public static synchronized boolean isGlobalScreenClaimed(@Nullable Screen screen) {
        return screen != null && globalScreenClaim != null && globalScreenClaim.active &&
            globalScreenClaim.screen == screen;
    }

    /** Returns the claimed lifecycle owner without changing it. */
    @Nullable
    public static synchronized Screen claimedGlobalScreen() {
        return globalScreenClaim == null || !globalScreenClaim.active ? null : globalScreenClaim.screen;
    }

    /** True only while the active claim still matches {@code Gui.screen()}. */
    public static boolean isCurrentGlobalScreenClaimed() {
        Minecraft minecraft = Minecraft.getInstance();
        return minecraft != null && minecraft.gui != null && isGlobalScreenClaimed(minecraft.gui.screen());
    }

    /**
     * Called at the head of {@code Gui.setScreen}, before vanilla invokes
     * {@link Screen#removed()}. Replacing a claimed screen only releases the
     * claim; native screen lifecycle remains entirely vanilla-owned.
     */
    public static synchronized void onGlobalScreenChanging(
        @Nullable Screen previousScreen, @Nullable Screen nextScreen)
    {
        GlobalScreenClaim claim = globalScreenClaim;
        if (claim == null || !claim.active || claim.screen != previousScreen || nextScreen == previousScreen) {
            return;
        }
        releaseGlobalScreenClaim(claim, nextScreen == null ?
            GlobalScreenLossReason.CLOSED : GlobalScreenLossReason.REPLACED, true);
    }

    /** Package-private current-screen seam for deterministic Host tests. */
    static synchronized GlobalScreenClaim claimGlobalScreenAgainst(
        String ownerId, Screen screen, @Nullable Screen currentScreen,
        @Nullable GlobalScreenClaimListener listener)
    {
        String validatedOwnerId = validateOwnerId(ownerId);
        Objects.requireNonNull(screen, "Claimed global screen cannot be null");
        if (screen != currentScreen) {
            throw new IllegalStateException("Only the current Gui.screen() can be claimed");
        }

        GlobalScreenClaim existing = globalScreenClaim;
        if (existing != null && existing.active) {
            if (existing.screen == screen && existing.ownerId.equals(validatedOwnerId)) {
                return existing;
            }
            throw new IllegalStateException(
                "Global screen is already claimed by " + existing.ownerId);
        }

        GlobalScreenClaim claim = new GlobalScreenClaim(validatedOwnerId, screen, listener);
        globalScreenClaim = claim;
        return claim;
    }

    /** Registers a multi-surface overlay and returns its owned lifecycle handle. */
    public static synchronized OverlayHandle registerSurface(OverlaySurface surface) {
        Objects.requireNonNull(surface, "External screen overlay cannot be null");
        String id = validateId(surface.id());
        OverlayHandle existing = SURFACES.get(id);
        if (existing != null) {
            if (existing.surface == surface) {
                return existing;
            }
            throw new IllegalStateException("An external screen overlay surface is already registered: " + id);
        }

        OverlayHandle handle = new OverlayHandle(surface, id, nextRegistrationOrder++);
        SURFACES.put(id, handle);
        SORTED_SURFACES.add(handle);
        renderOrderDirty = true;
        return handle;
    }

    /**
     * Legacy source/binary-compatible registration entry point. New add-ons
     * should retain the {@link OverlayHandle} returned by
     * {@link #registerSurface(OverlaySurface)}.
     */
    public static void register(Overlay candidate) {
        registerSurface(candidate);
    }

    public static synchronized void unregisterSurface(OverlaySurface candidate) {
        if (candidate == null) {
            return;
        }
        OverlayHandle handle = SURFACES.get(candidate.id());
        if (handle != null && handle.surface == candidate) {
            unregisterHandle(handle);
        }
    }

    /** Legacy single-overlay removal entry point. */
    public static void unregister(Overlay candidate) {
        unregisterSurface(candidate);
    }

    public static synchronized boolean isShowing() {
        for (OverlayHandle handle : sortedSurfaces()) {
            if (handle.isVisible()) {
                return true;
            }
        }
        return false;
    }

    /**
     * Returns whether a registered visible surface owns this controller. A
     * pressed surface keeps ownership through drag/release even if its ray
     * leaves the bounds, so Attack/Use is cancelled only for that one hand.
     */
    public static synchronized boolean isUsingController(ControllerType controller) {
        if (controller == null) {
            return false;
        }
        OverlayHandle pressed = PRESSED_SURFACES.get(controller);
        OverlayHandle focused = FOCUSED_SURFACES.get(controller);
        if ((pressed != null && pressed.registered && pressed.isVisible()) ||
            (focused != null && focused.registered && focused.isVisible()))
        {
            return true;
        }
        // A surface can open during processBindings, after this frame's focus
        // pass. Honor its explicit session claim immediately so world actions
        // cannot leak in that one-tick window.
        for (OverlayHandle handle : sortedSurfaces()) {
            if (handle.isVisible() && handle.surface.isUsingController(controller)) {
                return true;
            }
        }
        return false;
    }

    /**
     * Lets a visible surface suppress only a specific held-item render. This
     * changes neither the inventory stack nor any item gameplay behavior.
     */
    public static synchronized boolean shouldHideHeldItem(
        ControllerType controller, ItemStack stack)
    {
        if (controller == null || stack == null || stack.isEmpty()) {
            return false;
        }
        for (OverlayHandle handle : sortedSurfaces()) {
            if (handle.isVisible() && handle.surface.shouldHideHeldItem(controller, stack)) {
                return true;
            }
        }
        return false;
    }

    /** True only when this controller owns handler-dispatched pointer input. */
    public static synchronized boolean isUsingPointerController(ControllerType controller) {
        if (controller == null) {
            return false;
        }
        OverlayHandle pressed = PRESSED_SURFACES.get(controller);
        if (pressed != null && pressed.registered && pressed.isVisible()) {
            return pressed.surface.handlesPointerEvents();
        }
        OverlayHandle focused = FOCUSED_SURFACES.get(controller);
        if (focused != null && focused.registered && focused.isVisible()) {
            return focused.surface.handlesPointerEvents();
        }

        // Before the next focus pass, mirror the normal low-to-high priority
        // arbitration instead of allowing an obscured pointer claimant to
        // suppress the controller's world action.
        OverlayHandle claimant = null;
        for (OverlayHandle handle : sortedSurfaces()) {
            if (handle.isVisible() && handle.surface.isUsingController(controller)) {
                claimant = handle;
            }
        }
        return claimant != null && claimant.surface.handlesPointerEvents();
    }

    /**
     * True while a registered pointer surface owns at least one controller, or
     * while a claimed native screen must absorb GUI pointer input. GuiHandler
     * uses this before it simulates desktop mouse events so those events can be
     * dispatched exactly once by this registry instead.
     */
    public static synchronized boolean ownsPointerInput() {
        if (isCurrentGlobalScreenClaimed()) {
            return true;
        }
        for (ControllerType controller : ControllerType.values()) {
            OverlayHandle pressed = PRESSED_SURFACES.get(controller);
            OverlayHandle focused = FOCUSED_SURFACES.get(controller);
            if ((pressed != null && pressed.registered && pressed.isVisible() &&
                pressed.surface.handlesPointerEvents()) ||
                (focused != null && focused.registered && focused.isVisible() &&
                    focused.surface.handlesPointerEvents()))
            {
                return true;
            }
        }
        return false;
    }

    /** Returns an immutable registration-order snapshot. */
    public static synchronized List<OverlayHandle> surfaces() {
        return List.copyOf(SURFACES.values());
    }

    @Nullable
    public static synchronized OverlayHandle findSurface(String id) {
        return SURFACES.get(id);
    }

    /**
     * Legacy primary framebuffer view. With multiple surfaces this is the
     * highest-priority visible legacy surface.
     */
    @Nullable
    public static synchronized RenderTarget framebuffer() {
        OverlayHandle handle = primaryVisibleHandle(true);
        return handle == null ? null : handle.framebuffer;
    }

    /** Legacy primary overlay view. */
    @Nullable
    public static synchronized Overlay overlay() {
        OverlayHandle handle = primaryVisibleHandle(true);
        return handle == null ? null : (Overlay) handle.surface;
    }

    /** Ensures all currently visible surfaces have correctly sized targets. */
    public static synchronized void ensureFramebuffers() {
        for (OverlayHandle handle : sortedSurfaces()) {
            if (handle.isVisible()) {
                ensureFramebuffer(handle);
            }
        }
    }

    /** Legacy name retained for source compatibility. */
    public static void ensureFramebuffer() {
        ensureFramebuffers();
    }

    /** Releases every surface target without unregistering the surfaces. */
    public static synchronized void destroyFramebuffers() {
        for (OverlayHandle handle : SURFACES.values()) {
            handle.destroyFramebuffer();
        }
    }

    /** Legacy name retained for source compatibility. */
    public static void destroyFramebuffer() {
        destroyFramebuffers();
    }

    /**
     * Renders each visible surface once before the stereo world passes. The
     * same targets are later submitted as quads in both eye passes.
     */
    public static synchronized void render2D() {
        Minecraft minecraft = Minecraft.getInstance();
        if (minecraft == null || minecraft.gameRenderer == null) {
            return;
        }

        long frameTimeNanos = System.nanoTime();
        RenderTarget previousTarget = minecraft.gameRenderer.mainRenderTarget;
        try {
            for (OverlayHandle handle : sortedSurfaces()) {
                if (!handle.isVisible()) {
                    continue;
                }
                ensureFramebuffer(handle);
                if (handle.framebuffer == null) {
                    continue;
                }

                RenderCursor cursor = handle.renderCursor();
                boolean surfaceWantsRedraw = handle.surface.shouldRedraw(frameTimeNanos, cursor);
                if (handle.contentFramebuffer != null) {
                    renderRetainedSurface(
                        minecraft, handle, cursor, frameTimeNanos, surfaceWantsRedraw);
                    continue;
                }
                if (handle.hasRendered && !surfaceWantsRedraw) {
                    // The target is private to this surface and is reused in
                    // both eye passes. Retaining its last complete contents is
                    // cheaper than clearing and rebuilding an unchanged GUI.
                    continue;
                }

                minecraft.gameRenderer.mainRenderTarget = handle.framebuffer;
                RenderHelper.beginSurfaceGuiScope(
                    handle.guiMetrics, minecraft.gameRenderer.gameRenderState().windowRenderState);
                try {
                    RenderSystem.getDevice().createCommandEncoder().clearColorAndDepthTextures(
                        handle.framebuffer.getColorTexture(), MathUtils.BLACK_TRANSPARENT,
                        handle.framebuffer.getDepthTexture(), 0.0);
                    handle.surface.renderSurface(handle.framebuffer, cursor);
                    handle.surface.renderCarriedItem(handle.framebuffer, cursor);
                    handle.surface.redrawCompleted(frameTimeNanos, cursor);
                    handle.hasRendered = true;
                } finally {
                    handle.guiMetrics.exit();
                }
            }
        } finally {
            minecraft.gameRenderer.mainRenderTarget = previousTarget;
        }
    }

    /**
     * Rebuilds an expensive GUI into a private content target only when it is
     * dirty, then composes that retained image plus the live pointer/carried
     * pass into a clean presentation target every frame. Clearing before the
     * blit is important: when a pointer or carried item disappears, no pixels
     * from the previous presentation survive as a ghost.
     */
    private static void renderRetainedSurface(
        Minecraft minecraft,
        OverlayHandle handle,
        RenderCursor cursor,
        long frameTimeNanos,
        boolean surfaceWantsRedraw)
    {
        RenderTarget contentTarget = handle.contentFramebuffer;
        RenderTarget presentationTarget = handle.framebuffer;
        if (contentTarget == null || presentationTarget == null) {
            return;
        }

        if (!handle.contentHasRendered || surfaceWantsRedraw) {
            minecraft.gameRenderer.mainRenderTarget = contentTarget;
            RenderHelper.beginSurfaceGuiScope(
                handle.contentGuiMetrics, minecraft.gameRenderer.gameRenderState().windowRenderState);
            try {
                clearTarget(contentTarget);
                handle.surface.renderSurface(contentTarget, cursor);
                // Commit the surface's redraw snapshot only after extraction
                // completed. A thrown render therefore retries next frame.
                handle.surface.redrawCompleted(frameTimeNanos, cursor);
                handle.contentHasRendered = true;
                handle.contentRenderCount++;
            } finally {
                handle.contentGuiMetrics.exit();
            }
        }

        minecraft.gameRenderer.mainRenderTarget = presentationTarget;
        RenderHelper.beginSurfaceGuiScope(
            handle.guiMetrics, minecraft.gameRenderer.gameRenderState().windowRenderState);
        try {
            clearTarget(presentationTarget);
            // Presentation was cleared to transparent, so restore both RGB
            // and alpha without blending before drawing live decorations.
            ShaderHelper.blitRgba(contentTarget, presentationTarget);
            handle.surface.renderCarriedItem(presentationTarget, cursor);
            if (handle.framebufferMipmaps) {
                // Retained surfaces defer mip generation until both the base
                // blit and live decoration pass are complete. This is exactly
                // one generation per presentation, rather than one in each
                // contributing pass.
                GraphicsHelper.INSTANCE.genMipmaps(presentationTarget.getColorTexture());
            }
            handle.hasRendered = true;
            handle.presentationRenderCount++;
        } finally {
            handle.guiMetrics.exit();
        }
    }

    private static void clearTarget(RenderTarget target) {
        RenderSystem.getDevice().createCommandEncoder().clearColorAndDepthTextures(
            target.getColorTexture(), MathUtils.BLACK_TRANSPARENT,
            target.getDepthTexture(), 0.0);
    }

    /** Updates every visible surface and resolves one focus winner per hand. */
    public static synchronized void processGui() {
        for (OverlayHandle handle : sortedSurfaces()) {
            if (handle.isVisible()) {
                handle.surface.processGui();
            }
        }
        resolveFocus();
        dispatchPointerMotion();
    }

    /**
     * Dispatches pointer button edges to opt-in surfaces, then lets every
     * surface process its non-pointer bindings.
     */
    public static synchronized void processBindings() {
        resolveFocus();
        for (ControllerType controller : ControllerType.values()) {
            boolean pressedEdge = false;
            OverlayHandle focused = FOCUSED_SURFACES.get(controller);
            if (focused != null && focused.surface.handlesPointerEvents()) {
                pressedEdge = GuiHandler.KEY_KEYBOARD_CLICK.consumeClick(controller);
            }
            processPointerButton(controller, PointerButton.PRIMARY, pressedEdge,
                GuiHandler.KEY_KEYBOARD_CLICK.isDown(controller), PointerSource.HANDED_PRIMARY);
        }

        VRInputAction secondaryAction = ClientDataHolderVR.getInstance().vr == null ? null :
            ClientDataHolderVR.getInstance().vr.getInputAction(GuiHandler.KEY_EXTERNAL_SECONDARY);
        for (ControllerType controller : ControllerType.values()) {
            // This queue can be populated while another keyboard-category UI
            // owns the action set. Drain every edge; raw OpenXR state below is
            // the sole authority for a fresh, owner-scoped press.
            while (GuiHandler.KEY_EXTERNAL_SECONDARY.consumeClick(controller)) {
                // drain
            }
            OverlayHandle owner = pointerOwner(controller, PointerSource.HANDED_SECONDARY);
            boolean active = secondaryAction != null && secondaryAction.isActive(controller);
            long origin = active ? secondaryAction.getLastOrigin(controller) : 0L;
            boolean rawDown = active && secondaryAction.isButtonPressed(controller);
            ExternalPointerFreshPressGate.Routing routing = SECONDARY_PRESS_GATE.update(
                controller, owner, active, origin, rawDown);
            processPointerButton(controller, PointerButton.SECONDARY, routing.pressedEdge(),
                routing.buttonDown(), PointerSource.HANDED_SECONDARY);
        }

        processGlobalPointerButton(GuiHandler.KEY_LEFT_CLICK, PointerButton.PRIMARY,
            PointerSource.GLOBAL_PRIMARY);
        processGlobalPointerButton(GuiHandler.KEY_RIGHT_CLICK, PointerButton.SECONDARY,
            PointerSource.GLOBAL_SECONDARY);
        processGlobalPointerButton(GuiHandler.KEY_MIDDLE_CLICK, PointerButton.MIDDLE,
            PointerSource.GLOBAL_MIDDLE);
        processGlobalPointerScroll(GuiHandler.KEY_SCROLL_UP, 4.0D);
        processGlobalPointerScroll(GuiHandler.KEY_SCROLL_DOWN, -4.0D);

        for (OverlayHandle handle : sortedSurfaces()) {
            if (handle.isVisible()) {
                handle.surface.processBindings();
            }
        }
    }

    /**
     * Copies the visible low-to-high priority surfaces into a render-state
     * snapshot owned by the current VR frame.
     */
    public static synchronized void copyVisibleSurfaces(List<OverlayHandle> destination) {
        destination.clear();
        for (OverlayHandle handle : sortedSurfaces()) {
            if (handle.isVisible()) {
                destination.add(handle);
            }
        }
    }

    private static void resolveFocus() {
        for (ControllerType controller : ControllerType.values()) {
            OverlayHandle pressed = PRESSED_SURFACES.get(controller);
            if (pressed != null && (!pressed.registered || !pressed.isVisible())) {
                releasePressedSurface(controller, pressed);
            }
            OverlayHandle previous = FOCUSED_SURFACES.get(controller);
            OverlayHandle winner = null;

            // Render order is low-to-high priority, so the last matching
            // surface is the visually topmost and input-winning surface.
            for (OverlayHandle handle : sortedSurfaces()) {
                if (!handle.isVisible()) {
                    handle.clearCursor(controller);
                    continue;
                }
                handle.refreshCursor(controller);
                if (handle.wantsFocus(controller)) {
                    winner = handle;
                }
            }

            if (previous != winner) {
                if (previous != null && previous.registered) {
                    previous.focused[controller.ordinal()] = false;
                    previous.cursorHistoryValid[controller.ordinal()] = false;
                    previous.surface.focusChanged(controller, false);
                }
                if (winner != null) {
                    winner.focused[controller.ordinal()] = true;
                    winner.cursorHistoryValid[controller.ordinal()] = false;
                    winner.surface.focusChanged(controller, true);
                }
            } else if (winner != null) {
                winner.focused[controller.ordinal()] = true;
            }
            if (winner == null) {
                FOCUSED_SURFACES.remove(controller);
            } else {
                FOCUSED_SURFACES.put(controller, winner);
            }
        }
    }

    private static void dispatchPointerMotion() {
        for (ControllerType controller : ControllerType.values()) {
            OverlayHandle pressed = PRESSED_SURFACES.get(controller);
            OverlayHandle recipient = pressed != null && pressed.registered ? pressed :
                FOCUSED_SURFACES.get(controller);
            if (recipient == null || !recipient.isVisible() || !recipient.surface.handlesPointerEvents()) {
                continue;
            }

            RenderCursor cursor = recipient.cursor(controller);
            if (!cursor.valid()) {
                if (pressed == recipient) {
                    cancelPressedSurface(controller, recipient);
                }
                continue;
            }
            int index = controller.ordinal();
            double deltaX = recipient.cursorHistoryValid[index] ? cursor.x() - recipient.lastCursorX[index] : 0.0;
            double deltaY = recipient.cursorHistoryValid[index] ? cursor.y() - recipient.lastCursorY[index] : 0.0;
            recipient.surface.pointerMoved(controller, cursor, deltaX, deltaY);
            if (pressed == recipient) {
                PointerButton button = PRESSED_BUTTONS.getOrDefault(controller, PointerButton.PRIMARY);
                recipient.surface.pointerDragged(controller, cursor, button, deltaX, deltaY);
            }
            recipient.lastCursorX[index] = cursor.x();
            recipient.lastCursorY[index] = cursor.y();
            recipient.cursorHistoryValid[index] = true;
        }
    }

    /** Package-private deterministic edge dispatcher used by Host tests. */
    static void processPointerButton(ControllerType controller, boolean pressedEdge, boolean buttonDown) {
        processPointerButton(controller, PointerButton.PRIMARY, pressedEdge, buttonDown,
            PointerSource.TEST);
    }

    /** Package-private button-aware deterministic seam used by Host tests. */
    static void processPointerButton(ControllerType controller, PointerButton button,
                                     boolean pressedEdge, boolean buttonDown)
    {
        processPointerButton(controller, button, pressedEdge, buttonDown, PointerSource.TEST);
    }

    private static void processPointerButton(ControllerType controller, PointerButton button,
                                             boolean pressedEdge, boolean buttonDown,
                                             PointerSource source)
    {
        OverlayHandle pressed = PRESSED_SURFACES.get(controller);
        if (pressed != null && (!pressed.registered || !pressed.isVisible())) {
            cancelPressedSurface(controller, pressed);
            pressed = null;
        }

        if (pressed == null && pressedEdge) {
            OverlayHandle focused = FOCUSED_SURFACES.get(controller);
            if (focused != null && focused.registered && focused.isVisible() &&
                focused.surface.handlesPointerEvents())
            {
                RenderCursor cursor = focused.cursor(controller);
                if (cursor.valid()) {
                    PRESSED_SURFACES.put(controller, focused);
                    PRESSED_BUTTONS.put(controller, button);
                    PRESSED_SOURCES.put(controller, source);
                    cursor.pressed = true;
                    focused.surface.pointerPressed(controller, cursor, button);
                    pressed = focused;
                }
            }
        }

        if (pressed != null && PRESSED_SOURCES.get(controller) == source && !buttonDown) {
            releasePressedSurface(controller, pressed);
        }
    }

    private static void releasePressedSurface(ControllerType controller, OverlayHandle pressed) {
        RenderCursor cursor = pressed.cursor(controller);
        PointerButton button = PRESSED_BUTTONS.getOrDefault(controller, PointerButton.PRIMARY);
        if (cursor.valid()) {
            pressed.surface.pointerReleased(controller, cursor, button);
        } else {
            pressed.surface.pointerCancelled(controller, button);
        }
        cursor.pressed = false;
        PRESSED_SURFACES.remove(controller);
        PRESSED_BUTTONS.remove(controller);
        PRESSED_SOURCES.remove(controller);
    }

    private static void cancelPressedSurface(ControllerType controller, OverlayHandle pressed) {
        PointerButton button = PRESSED_BUTTONS.getOrDefault(controller, PointerButton.PRIMARY);
        pressed.surface.pointerCancelled(controller, button);
        pressed.cursor(controller).pressed = false;
        PRESSED_SURFACES.remove(controller);
        PRESSED_BUTTONS.remove(controller);
        PRESSED_SOURCES.remove(controller);
    }

    private static void processGlobalPointerButton(KeyMapping mapping, PointerButton button,
                                                   PointerSource source)
    {
        ControllerType activeController = pressedController(source);
        ControllerType originController = activeController == null ? controllerFor(mapping) : activeController;
        boolean capture = activeController != null || ownsPointerInput();
        if (!capture) {
            return;
        }
        boolean pressedEdge = mapping.consumeClick();
        if (originController != null) {
            processPointerButton(originController, button, pressedEdge, mapping.isDown(), source);
        }
    }

    private static void processGlobalPointerScroll(KeyMapping mapping, double amount) {
        if (!ownsPointerInput()) {
            return;
        }
        boolean scrollEdge = mapping.consumeClick();
        if (!scrollEdge) {
            return;
        }
        ControllerType controller = controllerFor(mapping);
        OverlayHandle focused = controller == null ? null : FOCUSED_SURFACES.get(controller);
        if (focused == null || !focused.registered || !focused.isVisible() ||
            !focused.surface.handlesPointerEvents())
        {
            return;
        }
        RenderCursor cursor = focused.cursor(controller);
        if (cursor.valid()) {
            processPointerScroll(controller, amount);
        }
    }

    /** Package-private deterministic scroll seam used by Host tests. */
    static void processPointerScroll(ControllerType controller, double amount) {
        OverlayHandle focused = FOCUSED_SURFACES.get(controller);
        if (focused == null || !focused.registered || !focused.isVisible() ||
            !focused.surface.handlesPointerEvents() || !Double.isFinite(amount) || amount == 0.0D)
        {
            return;
        }
        RenderCursor cursor = focused.cursor(controller);
        if (cursor.valid()) {
            focused.surface.pointerScrolled(controller, cursor, amount);
        }
    }

    @Nullable
    private static ControllerType pressedController(PointerSource source) {
        for (ControllerType controller : ControllerType.values()) {
            if (PRESSED_SOURCES.get(controller) == source) {
                return controller;
            }
        }
        return null;
    }

    @Nullable
    private static OverlayHandle pointerOwner(ControllerType controller, PointerSource source) {
        OverlayHandle pressed = PRESSED_SURFACES.get(controller);
        if (pressed != null && PRESSED_SOURCES.get(controller) == source && pressed.registered &&
            pressed.isVisible() && pressed.surface.handlesPointerEvents())
        {
            return pressed;
        }
        OverlayHandle focused = FOCUSED_SURFACES.get(controller);
        return focused != null && focused.registered && focused.isVisible() &&
            focused.surface.handlesPointerEvents() ? focused : null;
    }

    @Nullable
    private static ControllerType controllerFor(KeyMapping mapping) {
        ClientDataHolderVR dataHolder = ClientDataHolderVR.getInstance();
        try {
            if (dataHolder.vr != null) {
                long origin = dataHolder.vr.getInputAction(mapping).getLastOrigin();
                if (origin != 0L) {
                    ControllerType controller = dataHolder.vr.getOriginControllerType(origin);
                    if (controller != null) {
                        return controller;
                    }
                }
            }
        } catch (RuntimeException ignored) {
            // An action may not exist yet during startup. Fall back only when
            // exactly one hand owns pointer focus, never guess between hands.
        }

        ControllerType onlyFocused = null;
        for (ControllerType controller : ControllerType.values()) {
            OverlayHandle focused = FOCUSED_SURFACES.get(controller);
            if (focused == null || !focused.registered || !focused.isVisible() ||
                !focused.surface.handlesPointerEvents())
            {
                continue;
            }
            if (onlyFocused != null) {
                return null;
            }
            onlyFocused = controller;
        }
        return onlyFocused;
    }

    private static void ensureFramebuffer(OverlayHandle handle) {
        int width = positive(handle.surface.renderWidth(), GuiHandler.GUI_WIDTH);
        int height = positive(handle.surface.renderHeight(), GuiHandler.GUI_HEIGHT);
        int scaledWidth = positive(handle.surface.scaledWidth(), GuiHandler.SCALED_WIDTH_MAX);
        int scaledHeight = positive(handle.surface.scaledHeight(), GuiHandler.SCALED_HEIGHT_MAX);
        boolean mipmapsEnabled = ClientDataHolderAccess.guiMipmaps() && handle.surface.usesMipmaps();
        boolean retainedContent = handle.surface.usesRetainedContentTarget();
        if (handle.framebuffer != null && handle.framebufferWidth == width &&
            handle.framebufferHeight == height && handle.scaledWidth == scaledWidth &&
            handle.scaledHeight == scaledHeight && handle.framebufferMipmaps == mipmapsEnabled &&
            handle.framebufferRetainedContent == retainedContent &&
            (!retainedContent || handle.contentFramebuffer != null))
        {
            return;
        }

        // A retained presentation owns one final mip generation after base +
        // dynamic composition. Suppress the helpers' intermediate updates.
        handle.guiMetrics.configure(
            width, height, scaledWidth, scaledHeight, retainedContent ? false : mipmapsEnabled);
        if (retainedContent) {
            // Content is never sampled at a distance in world space. It is
            // copied 1:1 into the presentation target, so a mip chain here is
            // pure work and previously cost multiple Vulkan blits per frame.
            handle.contentGuiMetrics.configure(width, height, scaledWidth, scaledHeight, false);
        }
        handle.destroyFramebuffer();
        handle.framebuffer = VRTextureTarget.builder("External Screen Overlay: " + handle.surface.name())
            .withSize(width, height)
            .withDepth()
            .withMipmaps(mipmapsEnabled)
            .build();
        if (retainedContent) {
            handle.contentFramebuffer = VRTextureTarget.builder(
                    "External Screen Overlay Content: " + handle.surface.name())
                .withSize(width, height)
                .withDepth()
                .withMipmaps(false)
                .build();
        }
        handle.framebufferWidth = width;
        handle.framebufferHeight = height;
        handle.scaledWidth = scaledWidth;
        handle.scaledHeight = scaledHeight;
        handle.framebufferMipmaps = mipmapsEnabled;
        handle.framebufferRetainedContent = retainedContent;
        handle.surface.resize(scaledWidth, scaledHeight);
    }

    private static int positive(int value, int fallback) {
        return value > 0 ? value : fallback;
    }

    private static List<OverlayHandle> sortedSurfaces() {
        if (renderOrderDirty) {
            SORTED_SURFACES.sort(RENDER_ORDER);
            renderOrderDirty = false;
        }
        return SORTED_SURFACES;
    }

    @Nullable
    private static OverlayHandle primaryVisibleHandle(boolean legacyOnly) {
        List<OverlayHandle> sorted = sortedSurfaces();
        for (int i = sorted.size() - 1; i >= 0; i--) {
            OverlayHandle handle = sorted.get(i);
            if (handle.isVisible() && (!legacyOnly || handle.surface instanceof Overlay)) {
                return handle;
            }
        }
        return null;
    }

    private static String validateId(String candidate) {
        if (candidate == null) {
            throw new IllegalArgumentException("External screen overlay id cannot be null");
        }
        String id = candidate.trim();
        if (id.isEmpty()) {
            throw new IllegalArgumentException("External screen overlay id cannot be blank");
        }
        return id;
    }

    private static String validateOwnerId(String candidate) {
        if (candidate == null) {
            throw new IllegalArgumentException("Global screen claim owner cannot be null");
        }
        String ownerId = candidate.trim();
        if (ownerId.isEmpty()) {
            throw new IllegalArgumentException("Global screen claim owner cannot be blank");
        }
        return ownerId;
    }

    private static synchronized void releaseGlobalScreenClaim(
        GlobalScreenClaim claim, GlobalScreenLossReason reason, boolean notifyListener)
    {
        if (!claim.active || globalScreenClaim != claim) {
            return;
        }
        globalScreenClaim = null;
        claim.active = false;
        if (notifyListener && claim.listener != null) {
            globalScreenCallbackDispatcher.accept(() -> notifyGlobalScreenClaimListener(claim, reason));
        }
    }

    private static void dispatchOnClientThread(Runnable callback) {
        Minecraft minecraft = Minecraft.getInstance();
        if (minecraft != null && !minecraft.isSameThread()) {
            minecraft.execute(callback);
        } else {
            callback.run();
        }
    }

    private static void notifyGlobalScreenClaimListener(
        GlobalScreenClaim claim, GlobalScreenLossReason reason)
    {
        GlobalScreenClaimListener listener = claim.listener;
        if (listener == null) {
            return;
        }
        try {
            listener.onLost(claim.screen, reason);
        } catch (Throwable throwable) {
            org.vivecraft.client_vr.settings.VRSettings.LOGGER.error(
                "Vivecraft: external global-screen claim listener failed for {}", claim.ownerId, throwable);
        }
    }

    private static synchronized void unregisterHandle(OverlayHandle handle) {
        if (!handle.registered || SURFACES.get(handle.id) != handle) {
            return;
        }

        for (ControllerType controller : ControllerType.values()) {
            if (PRESSED_SURFACES.get(controller) == handle) {
                cancelPressedSurface(controller, handle);
            }
            if (FOCUSED_SURFACES.get(controller) == handle) {
                FOCUSED_SURFACES.remove(controller);
                handle.focused[controller.ordinal()] = false;
                handle.surface.focusChanged(controller, false);
            }
        }
        SURFACES.remove(handle.id);
        SORTED_SURFACES.remove(handle);
        handle.registered = false;
        handle.destroyFramebuffer();
    }

    /** Test isolation without touching any device/runtime state. */
    static synchronized void resetRegistryForTests() {
        for (OverlayHandle handle : new ArrayList<>(SURFACES.values())) {
            unregisterHandle(handle);
        }
        SURFACES.clear();
        SORTED_SURFACES.clear();
        FOCUSED_SURFACES.clear();
        PRESSED_SURFACES.clear();
        PRESSED_BUTTONS.clear();
        PRESSED_SOURCES.clear();
        SECONDARY_PRESS_GATE.reset();
        nextRegistrationOrder = 0L;
        renderOrderDirty = false;
        if (globalScreenClaim != null) {
            globalScreenClaim.active = false;
            globalScreenClaim = null;
        }
        globalScreenCallbackDispatcher = ExternalScreenOverlayHandler::dispatchOnClientThread;
    }

    static synchronized void setGlobalScreenCallbackDispatcherForTests(Consumer<Runnable> dispatcher) {
        globalScreenCallbackDispatcher = Objects.requireNonNull(dispatcher, "dispatcher");
    }

    /** Why a claimed screen stopped being externally owned. */
    public enum GlobalScreenLossReason {
        /** The owner explicitly released its rendering/input claim. */
        UNCLAIMED,
        /** Vanilla or another mod installed a different screen. */
        REPLACED,
        /** Vanilla was asked to close the screen. */
        CLOSED
    }

    @FunctionalInterface
    public interface GlobalScreenClaimListener {
        void onLost(Screen screen, GlobalScreenLossReason reason);
    }

    /**
     * Identity handle for one claim. {@link #close()} only relinquishes the
     * claim; it deliberately performs no native screen lifecycle operation.
     */
    public static final class GlobalScreenClaim implements AutoCloseable {
        private final String ownerId;
        private final Screen screen;
        @Nullable
        private final GlobalScreenClaimListener listener;
        private volatile boolean active = true;

        private GlobalScreenClaim(
            String ownerId, Screen screen, @Nullable GlobalScreenClaimListener listener)
        {
            this.ownerId = ownerId;
            this.screen = screen;
            this.listener = listener;
        }

        public String ownerId() {
            return this.ownerId;
        }

        public Screen screen() {
            return this.screen;
        }

        public boolean isActive() {
            return this.active;
        }

        @Override
        public void close() {
            releaseGlobalScreenClaim(this, GlobalScreenLossReason.UNCLAIMED, true);
        }
    }

    /**
     * New multi-surface contract. Values are in Vivecraft room space unless
     * otherwise documented.
     */
    public interface OverlaySurface {
        /** Stable registry key. Legacy surfaces default to their name. */
        default String id() {
            return name();
        }

        String name();

        /** Screen-backed surfaces can use the default {@link #renderSurface}. */
        @Nullable
        Screen screen();

        boolean isShowing();

        Vector3fc roomPosition();

        Matrix4fc roomRotation();

        float scale();

        /** Higher priority renders later and wins overlapping pointer focus. */
        default int priority() {
            return 0;
        }

        /** Whether world depth may cover this surface. */
        default ExternalOverlayRenderPolicy.WorldOcclusion worldOcclusion() {
            return ExternalOverlayRenderPolicy.WorldOcclusion.INHERIT_GUI;
        }

        /**
         * Allows a surface to hide one held item while visible. Implementations
         * must inspect both logical controller and stack; the default preserves
         * every held item.
         */
        default boolean shouldHideHeldItem(ControllerType controller, ItemStack stack) {
            return false;
        }

        /** Logical interaction bounds inside the scaled surface. */
        default SurfaceBounds bounds() {
            return SurfaceBounds.full();
        }

        default int renderWidth() {
            return GuiHandler.GUI_WIDTH;
        }

        default int renderHeight() {
            return GuiHandler.GUI_HEIGHT;
        }

        default int scaledWidth() {
            return GuiHandler.SCALED_WIDTH_MAX;
        }

        default int scaledHeight() {
            return GuiHandler.SCALED_HEIGHT_MAX;
        }

        default void resize(int scaledWidth, int scaledHeight) {
        }

        default void processGui() {
        }

        /** Non-pointer bindings only when {@link #handlesPointerEvents()} is true. */
        default void processBindings() {
        }

        /**
         * Allows a surface with a private retained target to skip rebuilding
         * unchanged pixels. Returning {@code false} never skips the first
         * render after target creation or resize. Interactive surfaces should
         * request redraws whenever cursor, drag, carried-item or animation
         * state requires fresh pixels.
         */
        default boolean shouldRedraw(long frameTimeNanos, RenderCursor cursor) {
            return true;
        }

        /**
         * Keeps the expensive base GUI in a second private target. The base is
         * rebuilt according to {@link #shouldRedraw}, while the presentation
         * target is cleared and recomposed every frame so pointer and carried
         * item motion remains headset-rate smooth.
         */
        default boolean usesRetainedContentTarget() {
            return false;
        }

        /**
         * Called only after a requested base redraw completed successfully.
         * Retained surfaces use this to commit a dirty-state snapshot without
         * suppressing a retry when extraction throws.
         */
        default void redrawCompleted(long frameTimeNanos, RenderCursor cursor) {
        }

        /** Allows high-frequency surfaces to opt out of GUI mip generation. */
        default boolean usesMipmaps() {
            return true;
        }

        /** Per-controller cursor snapshot. */
        default RenderCursor cursor(ControllerType controller) {
            RenderCursor cursor = renderCursor();
            return cursor.valid() && cursor.controller() == controller ? cursor : RenderCursor.invalid();
        }

        /** Legacy primary cursor view. */
        default RenderCursor renderCursor() {
            return RenderCursor.invalid();
        }

        /** Raw ownership request before registry priority arbitration. */
        default boolean isUsingController(ControllerType controller) {
            return false;
        }

        /** Opt in to handler-owned click/drag/release dispatch. */
        default boolean handlesPointerEvents() {
            return false;
        }

        /** Custom framebuffer-only surfaces can render without a Screen. */
        default boolean hasCustomRenderer() {
            return false;
        }

        default void focusChanged(ControllerType controller, boolean focused) {
        }

        default void pointerMoved(ControllerType controller, RenderCursor cursor, double deltaX, double deltaY) {
        }

        default void pointerPressed(ControllerType controller, RenderCursor cursor) {
        }

        /** Button-aware entry point; legacy surfaces continue to receive primary clicks. */
        default void pointerPressed(ControllerType controller, RenderCursor cursor, PointerButton button) {
            if (button == PointerButton.PRIMARY) {
                pointerPressed(controller, cursor);
            }
        }

        default void pointerDragged(ControllerType controller, RenderCursor cursor, double deltaX, double deltaY) {
        }

        /** Button-aware drag entry point. */
        default void pointerDragged(ControllerType controller, RenderCursor cursor, PointerButton button,
                                    double deltaX, double deltaY)
        {
            if (button == PointerButton.PRIMARY) {
                pointerDragged(controller, cursor, deltaX, deltaY);
            }
        }

        default void pointerReleased(ControllerType controller, RenderCursor cursor) {
        }

        /** Button-aware release entry point. */
        default void pointerReleased(ControllerType controller, RenderCursor cursor, PointerButton button) {
            if (button == PointerButton.PRIMARY) {
                pointerReleased(controller, cursor);
            }
        }

        /**
         * Cancels a press when tracking or the surface disappears. Implementors
         * must clear local drag state without replaying a stale cursor position.
         */
        default void pointerCancelled(ControllerType controller, PointerButton button) {
        }

        /** Scroll amount follows Minecraft's vertical scroll convention. */
        default void pointerScrolled(ControllerType controller, RenderCursor cursor, double amount) {
        }

        /**
         * Called with this surface's target bound. The default records and
         * replays its Screen without ever assigning it to Minecraft.setScreen.
         */
        default void renderSurface(RenderTarget target, RenderCursor cursor) {
            Screen screen = screen();
            if (screen == null) {
                return;
            }
            int mouseX = cursor.valid() ? (int) Math.round(cursor.x()) : -10_000;
            int mouseY = cursor.valid() ? (int) Math.round(cursor.y()) : -10_000;
            RenderHelper.drawScreen(screen, true, mouseX, mouseY);
        }

        /** Optional second pass for a carried stack/cursor decoration. */
        default void renderCarriedItem(RenderTarget target, RenderCursor cursor) {
        }
    }

    /** Legacy contract retained for the existing VEQ surface. */
    public interface Overlay extends OverlaySurface {
    }

    /** Owned registration and render-state handle for one surface. */
    public static final class OverlayHandle implements AutoCloseable {
        private final OverlaySurface surface;
        private final String id;
        private final long registrationOrder;
        private final RenderCursor[] cursors = new RenderCursor[ControllerType.values().length];
        private final boolean[] focused = new boolean[ControllerType.values().length];
        private final double[] lastCursorX = new double[ControllerType.values().length];
        private final double[] lastCursorY = new double[ControllerType.values().length];
        private final boolean[] cursorHistoryValid = new boolean[ControllerType.values().length];
        private final ScreenRenderState renderState = new ScreenRenderState();
        private final SurfaceGuiMetrics guiMetrics = new SurfaceGuiMetrics();
        private final SurfaceGuiMetrics contentGuiMetrics = new SurfaceGuiMetrics();

        @Nullable
        private RenderTarget framebuffer;
        @Nullable
        private RenderTarget contentFramebuffer;
        private int framebufferWidth;
        private int framebufferHeight;
        private int scaledWidth;
        private int scaledHeight;
        private boolean framebufferMipmaps;
        private boolean framebufferRetainedContent;
        private boolean registered = true;
        private boolean hasRendered;
        private boolean contentHasRendered;
        private long contentRenderCount;
        private long presentationRenderCount;

        private OverlayHandle(OverlaySurface surface, String id, long registrationOrder) {
            this.surface = surface;
            this.id = id;
            this.registrationOrder = registrationOrder;
            for (ControllerType controller : ControllerType.values()) {
                this.cursors[controller.ordinal()] = new RenderCursor();
            }
        }

        public String id() {
            return this.id;
        }

        public OverlaySurface surface() {
            return this.surface;
        }

        @Nullable
        public RenderTarget framebuffer() {
            return this.framebuffer;
        }

        public RenderCursor cursor(ControllerType controller) {
            return this.cursors[Objects.requireNonNull(controller, "controller").ordinal()];
        }

        public boolean isFocused(ControllerType controller) {
            return controller != null && this.focused[controller.ordinal()];
        }

        public boolean isRegistered() {
            return this.registered;
        }

        public int scaledWidth() {
            return this.scaledWidth > 0 ? this.scaledWidth : this.surface.scaledWidth();
        }

        public int scaledHeight() {
            return this.scaledHeight > 0 ? this.scaledHeight : this.surface.scaledHeight();
        }

        /** Internal per-frame world-space state consumed by both eye passes. */
        public ScreenRenderState renderState() {
            return this.renderState;
        }

        long registrationOrder() {
            return this.registrationOrder;
        }

        boolean isVisible() {
            return this.registered && this.surface.isShowing() &&
                (this.surface.screen() != null || this.surface.hasCustomRenderer());
        }

        private void refreshCursor(ControllerType controller) {
            RenderCursor source = this.surface.cursor(controller);
            RenderCursor cursor = this.cursors[controller.ordinal()];
            cursor.copyFrom(source);
            if (!cursor.valid() || cursor.controller() != controller) {
                cursor.setInvalid();
            } else if (PRESSED_SURFACES.get(controller) == this) {
                cursor.pressed = true;
            }
        }

        private boolean wantsFocus(ControllerType controller) {
            RenderCursor cursor = cursor(controller);
            int surfaceWidth = this.surface.scaledWidth();
            int surfaceHeight = this.surface.scaledHeight();
            if (surfaceWidth <= 0) {
                surfaceWidth = GuiHandler.SCALED_WIDTH_MAX;
            }
            if (surfaceHeight <= 0) {
                surfaceHeight = GuiHandler.SCALED_HEIGHT_MAX;
            }
            boolean cursorFocus = cursor.valid() && cursor.focused() &&
                this.surface.bounds().contains(cursor.x(), cursor.y(),
                    surfaceWidth, surfaceHeight);
            return cursorFocus || this.surface.isUsingController(controller);
        }

        private RenderCursor renderCursor() {
            for (ControllerType controller : ControllerType.values()) {
                if (PRESSED_SURFACES.get(controller) == this) {
                    return cursor(controller);
                }
            }
            for (ControllerType controller : ControllerType.values()) {
                if (isFocused(controller)) {
                    return cursor(controller);
                }
            }
            RenderCursor legacy = this.surface.renderCursor();
            return legacy == null ? RenderCursor.invalid() : legacy;
        }

        private void clearCursor(ControllerType controller) {
            int index = controller.ordinal();
            this.cursors[index].setInvalid();
            this.cursorHistoryValid[index] = false;
            this.focused[index] = false;
        }

        private void destroyFramebuffer() {
            if (this.framebuffer != null) {
                this.framebuffer.destroyBuffers();
                this.framebuffer = null;
            }
            if (this.contentFramebuffer != null) {
                this.contentFramebuffer.destroyBuffers();
                this.contentFramebuffer = null;
            }
            this.framebufferWidth = 0;
            this.framebufferHeight = 0;
            this.scaledWidth = 0;
            this.scaledHeight = 0;
            this.framebufferMipmaps = false;
            this.framebufferRetainedContent = false;
            this.hasRendered = false;
            this.contentHasRendered = false;
        }

        @Override
        public void close() {
            unregisterHandle(this);
        }
    }

    /** Mouse-compatible logical buttons dispatched to overlay surfaces. */
    public enum PointerButton {
        PRIMARY(0),
        SECONDARY(1),
        MIDDLE(2);

        private final int mouseButton;

        PointerButton(int mouseButton) {
            this.mouseButton = mouseButton;
        }

        public int mouseButton() {
            return this.mouseButton;
        }
    }

    private enum PointerSource {
        HANDED_PRIMARY,
        HANDED_SECONDARY,
        GLOBAL_PRIMARY,
        GLOBAL_SECONDARY,
        GLOBAL_MIDDLE,
        TEST
    }

    /** Logical-pixel input rectangle for one surface. */
    public static final class SurfaceBounds {
        private static final SurfaceBounds FULL = new SurfaceBounds(0, 0, -1, -1, true);

        private final int x;
        private final int y;
        private final int width;
        private final int height;
        private final boolean full;

        public SurfaceBounds(int x, int y, int width, int height) {
            this(x, y, width, height, false);
            if (x < 0 || y < 0 || width <= 0 || height <= 0) {
                throw new IllegalArgumentException("Surface bounds require non-negative origin and positive size");
            }
        }

        private SurfaceBounds(int x, int y, int width, int height, boolean full) {
            this.x = x;
            this.y = y;
            this.width = width;
            this.height = height;
            this.full = full;
        }

        public static SurfaceBounds full() {
            return FULL;
        }

        public int x() {
            return this.x;
        }

        public int y() {
            return this.y;
        }

        public int width() {
            return this.width;
        }

        public int height() {
            return this.height;
        }

        public boolean isFull() {
            return this.full;
        }

        public boolean contains(double cursorX, double cursorY, int surfaceWidth, int surfaceHeight) {
            if (!Double.isFinite(cursorX) || !Double.isFinite(cursorY)) {
                return false;
            }
            int left = this.full ? 0 : this.x;
            int top = this.full ? 0 : this.y;
            int right = this.full ? surfaceWidth : this.x + this.width;
            int bottom = this.full ? surfaceHeight : this.y + this.height;
            return cursorX >= left && cursorX <= right && cursorY >= top && cursorY <= bottom;
        }

        /**
         * Resolves this logical focus rectangle into a framebuffer crop.  The
         * same rectangle is used by input and rendering so a compact wrist UI
         * no longer expands transparent margins to the size of the full GUI
         * quad.  Dynamic VEP effect/status rows can safely change this every
         * frame without resizing the render target.
         */
        public ResolvedSurfaceBounds resolve(int surfaceWidth, int surfaceHeight) {
            int safeWidth = Math.max(1, surfaceWidth);
            int safeHeight = Math.max(1, surfaceHeight);
            if (this.full) {
                return new ResolvedSurfaceBounds(0, 0, safeWidth, safeHeight);
            }
            int left = Math.min(safeWidth, Math.max(0, this.x));
            int top = Math.min(safeHeight, Math.max(0, this.y));
            int right = Math.min(safeWidth, Math.max(left, this.x + this.width));
            int bottom = Math.min(safeHeight, Math.max(top, this.y + this.height));
            if (right <= left || bottom <= top) {
                return new ResolvedSurfaceBounds(0, 0, safeWidth, safeHeight);
            }
            return new ResolvedSurfaceBounds(left, top, right - left, bottom - top);
        }
    }

    /** Immutable, clamped crop in logical surface pixels. */
    public record ResolvedSurfaceBounds(int x, int y, int width, int height) {
        public float u0(int surfaceWidth) {
            return x / (float) Math.max(1, surfaceWidth);
        }

        public float v0(int surfaceHeight) {
            return y / (float) Math.max(1, surfaceHeight);
        }

        public float u1(int surfaceWidth) {
            return (x + width) / (float) Math.max(1, surfaceWidth);
        }

        public float v1(int surfaceHeight) {
            return (y + height) / (float) Math.max(1, surfaceHeight);
        }

        /**
         * RenderTarget textures are vertically inverted relative to Minecraft
         * screen coordinates. These values place a logical top-down crop on
         * the quad's bottom-up Y axis while preserving the full-quad mapping.
         */
        public float quadVBottom(int surfaceHeight) {
            return 1.0F - v1(surfaceHeight);
        }

        public float quadVTop(int surfaceHeight) {
            return 1.0F - v0(surfaceHeight);
        }
    }

    /**
     * Mutable per-controller cursor snapshot. The old four-argument setter is
     * retained; new surfaces should set focused/pressed explicitly.
     */
    public static final class RenderCursor {
        private static final RenderCursor INVALID = new RenderCursor().setInvalid();

        private double x;
        private double y;
        @Nullable
        private ControllerType controller;
        private boolean valid;
        private boolean focused;
        private boolean pressed;

        public RenderCursor() {
            setInvalid();
        }

        public RenderCursor(double x, double y, @Nullable ControllerType controller, boolean valid) {
            set(x, y, controller, valid);
        }

        public RenderCursor set(double x, double y, @Nullable ControllerType controller, boolean valid) {
            return set(x, y, controller, valid, valid, false);
        }

        public RenderCursor set(double x, double y, @Nullable ControllerType controller, boolean valid,
                                boolean focused, boolean pressed)
        {
            this.x = x;
            this.y = y;
            this.controller = controller;
            this.valid = valid && Double.isFinite(x) && Double.isFinite(y) && controller != null;
            this.focused = this.valid && focused;
            this.pressed = this.valid && pressed;
            return this;
        }

        public RenderCursor copyFrom(@Nullable RenderCursor other) {
            return other == null ? setInvalid() :
                set(other.x, other.y, other.controller, other.valid, other.focused, other.pressed);
        }

        public RenderCursor setInvalid() {
            this.x = -10_000.0;
            this.y = -10_000.0;
            this.controller = null;
            this.valid = false;
            this.focused = false;
            this.pressed = false;
            return this;
        }

        public double x() {
            return this.x;
        }

        public double y() {
            return this.y;
        }

        @Nullable
        public ControllerType controller() {
            return this.controller;
        }

        public boolean valid() {
            return this.valid;
        }

        public boolean focused() {
            return this.focused;
        }

        public boolean pressed() {
            return this.pressed;
        }

        public static RenderCursor invalid() {
            return INVALID;
        }
    }

    /** Avoids making the overlay contract depend on the full data-holder type. */
    private static final class ClientDataHolderAccess {
        private ClientDataHolderAccess() {
        }

        private static boolean guiMipmaps() {
            return org.vivecraft.client_vr.ClientDataHolderVR.getInstance().vrSettings.guiMipmaps;
        }
    }
}
