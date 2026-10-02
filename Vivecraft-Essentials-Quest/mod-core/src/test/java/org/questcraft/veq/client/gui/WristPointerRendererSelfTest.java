package org.questcraft.veq.client.gui;

import org.questcraft.veq.client.overlay.VepSurfacePointerRenderer;
import org.vivecraft.client_vr.gameplay.screenhandlers.ExternalScreenOverlayHandler;
import org.vivecraft.client_vr.provider.ControllerType;

/** Host-only surface-coordinate contract for the embedded wrist cursor. */
public final class WristPointerRendererSelfTest {
    private WristPointerRendererSelfTest() {
    }

    public static void main(String[] args) {
        require(VepSurfacePointerRenderer.isInsideSurface(0, 0, 504, 270),
                "top-left surface pixel must render");
        require(VepSurfacePointerRenderer.isInsideSurface(503, 269, 504, 270),
                "bottom-right surface pixel must render");
        require(VepSurfacePointerRenderer.isInsideSurface(1, 1, 504, 270),
                "an owned drag outside content keeps its real surface coordinate");
        require(!VepSurfacePointerRenderer.isInsideSurface(-1, 40, 504, 270),
                "negative x must not be clamped onto the wrist");
        require(!VepSurfacePointerRenderer.isInsideSurface(40, -1, 504, 270),
                "negative y must not be clamped onto the wrist");
        require(!VepSurfacePointerRenderer.isInsideSurface(504, 40, 504, 270),
                "right edge is outside the surface");
        require(!VepSurfacePointerRenderer.isInsideSurface(40, 270, 504, 270),
                "bottom edge is outside the surface");
        require(!VepSurfacePointerRenderer.isInsideSurface(0, 0, 0, 270),
                "invalid surface dimensions fail closed");
        require(VepSurfacePointerRenderer.isInsideUnitUv(0.0D, 0.0D),
                "the normalized top-left UV must focus the contextual surface");
        require(VepSurfacePointerRenderer.isInsideUnitUv(
                        Math.nextDown(1.0F), Math.nextDown(1.0F)),
                "the final representable UV below one must remain focused");
        require(!VepSurfacePointerRenderer.isInsideUnitUv(1.0D, 0.5D),
                "u == 1 is outside the contextual surface");
        require(!VepSurfacePointerRenderer.isInsideUnitUv(0.5D, 1.0D),
                "v == 1 is outside the contextual surface");
        require(!VepSurfacePointerRenderer.isInsideUnitUv(-0.01D, 0.5D),
                "negative normalized coordinates are outside");
        require(!VepSurfacePointerRenderer.isInsideUnitUv(Double.NaN, 0.5D),
                "non-finite normalized coordinates fail closed");

        ExternalScreenOverlayHandler.RenderCursor contextualCursor =
                new ExternalScreenOverlayHandler.RenderCursor(
                        123.25D, 78.75D, ControllerType.LEFT, true);
        require(VepSurfacePointerRenderer.canRender(contextualCursor, 504, 270),
                "a valid contextual RenderCursor must compose into its surface");
        contextualCursor.set(Double.NaN, 78.75D, ControllerType.LEFT, true);
        require(!VepSurfacePointerRenderer.canRender(contextualCursor, 504, 270),
                "non-finite contextual coordinates fail closed");
        contextualCursor.set(-0.4D, 78.75D, ControllerType.LEFT, true, true, false);
        require(!VepSurfacePointerRenderer.canRender(contextualCursor, 504, 270),
                "a negative fractional coordinate must be rejected before pixel mapping");
        contextualCursor.set(503.6D, 269.6D, ControllerType.LEFT, true, true, false);
        require(VepSurfacePointerRenderer.canRender(contextualCursor, 504, 270),
                "an in-bounds fractional coordinate must map to the final surface pixel");
        require(VepSurfacePointerRenderer.canReceiveInput(contextualCursor, 504, 270),
                "the final in-bounds fraction must remain interactive");
        contextualCursor.set(504.0D, 78.75D, ControllerType.LEFT, true);
        require(!VepSurfacePointerRenderer.canRender(contextualCursor, 504, 270),
                "a contextual drag beyond the surface is not edge-clamped");
        require(!VepSurfacePointerRenderer.canReceiveInput(contextualCursor, 504, 270),
                "the exact right edge must not dispatch a fresh input transaction");
        contextualCursor.set(40.0D, 270.0D, ControllerType.LEFT, true);
        require(!VepSurfacePointerRenderer.canReceiveInput(contextualCursor, 504, 270),
                "the exact bottom edge must not dispatch a fresh input transaction");
        contextualCursor.set(40.0D, 269.75D, ControllerType.LEFT, true, false, false);
        require(!VepSurfacePointerRenderer.canReceiveInput(contextualCursor, 504, 270),
                "an unfocused carried cursor cannot start a new transaction");
        contextualCursor.setInvalid();
        require(!VepSurfacePointerRenderer.canRender(contextualCursor, 504, 270),
                "an invalid contextual RenderCursor never draws a global cursor");
        System.out.println("WristPointerRendererSelfTest PASS");
    }

    private static void require(boolean condition, String message) {
        if (!condition) {
            throw new AssertionError(message);
        }
    }
}
