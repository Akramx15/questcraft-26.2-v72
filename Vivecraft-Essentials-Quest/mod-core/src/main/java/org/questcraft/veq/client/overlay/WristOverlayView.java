package org.questcraft.veq.client.overlay;

import net.minecraft.client.gui.screens.Screen;
import org.joml.Matrix4fc;
import org.joml.Vector3fc;
import org.vivecraft.client_vr.provider.ControllerType;
import org.vivecraft.client_vr.gameplay.screenhandlers.ExternalScreenOverlayHandler;

/** UI implementation consumed by the dedicated Vivecraft wrist surface. */
public interface WristOverlayView {
    Screen screen();

    void init(int scaledWidth, int scaledHeight);

    /**
     * Updates one controller ray against the supplied overlay-space surface.
     * The implementation obtains the controller pose from Vivecraft's latest
     * room data and returns whether the ray owns input priority.
     */
    boolean updatePointer(
            ControllerType controller,
            Vector3fc overlayPosition,
            Matrix4fc overlayRotation,
            float overlayScale
    );

    boolean isPointerFocused(ControllerType controller);

    /**
     * Whether this view can accept a new pointer press at its current cursor.
     * A view may retain input ownership beyond its ordinary focus bounds, for
     * example while the same controller owns Minecraft's carried stack.
     */
    default boolean acceptsPointerPress(
            ControllerType controller,
            ExternalScreenOverlayHandler.PointerButton button
    ) {
        return button != null && isPointerFocused(controller);
    }

    /** Pointer, drag, or carried-stack ownership for input arbitration. */
    default boolean ownsInput(ControllerType controller) {
        return isPointerFocused(controller);
    }

    /** Clears one controller when it becomes the wrist's anchor hand. */
    void clearPointer(ControllerType controller);

    /** Returns true only when this exact screen accepted and owns the press. */
    boolean press(ControllerType controller);

    void release(ControllerType controller);

    default boolean press(ControllerType controller,
                          ExternalScreenOverlayHandler.PointerButton button) {
        return button == ExternalScreenOverlayHandler.PointerButton.PRIMARY
                && press(controller);
    }

    default void release(ControllerType controller,
                         ExternalScreenOverlayHandler.PointerButton button) {
        if (button == ExternalScreenOverlayHandler.PointerButton.PRIMARY) {
            release(controller);
        }
    }

    default void cancel(ControllerType controller,
                        ExternalScreenOverlayHandler.PointerButton button) {
        release(controller, button);
    }

    default void scroll(ControllerType controller, double amount) {
    }

    default ExternalScreenOverlayHandler.RenderCursor renderCursor() {
        return ExternalScreenOverlayHandler.RenderCursor.invalid();
    }

    default ExternalScreenOverlayHandler.RenderCursor renderCursor(ControllerType controller) {
        ExternalScreenOverlayHandler.RenderCursor cursor = renderCursor();
        return cursor.valid() && cursor.controller() == controller
                ? cursor
                : ExternalScreenOverlayHandler.RenderCursor.invalid();
    }

    /** Stable content key under one controller, used to redraw hover visuals. */
    default int hoverKey(ControllerType controller) {
        return -1;
    }

    default ExternalScreenOverlayHandler.SurfaceBounds bounds() {
        return ExternalScreenOverlayHandler.SurfaceBounds.full();
    }

    /** Prevents gesture-driven closure while Minecraft is carrying a stack. */
    default boolean canHide() {
        return true;
    }

    default void onShown() {
    }

    /**
     * @param hardClose true for lifecycle/screen/tracking transitions that
     *                  must reconcile a carried stack, false for a gesture
     *                  soft-hide where the embedded menu stays live
     */
    default void onHidden(boolean hardClose) {
    }
}
