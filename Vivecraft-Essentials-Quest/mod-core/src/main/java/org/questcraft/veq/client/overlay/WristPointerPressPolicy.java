package org.questcraft.veq.client.overlay;

import org.vivecraft.client_vr.gameplay.screenhandlers.ExternalScreenOverlayHandler;

/**
 * Fail-closed press policy for a cropped wrist surface.
 *
 * <p>Ordinary focused clicks retain their existing behavior. Once one
 * controller owns Minecraft's carried stack, that exact controller may also
 * click the transparent area outside the embedded container content to invoke
 * Vanilla's outside-click drop path. The exception is bounded to the finite
 * wrist canvas and to primary/secondary clicks; it never grants the other hand
 * ownership and never turns passive VEP extensions into drop targets.</p>
 */
final class WristPointerPressPolicy {
    private WristPointerPressPolicy() {
    }

    static boolean accepts(
            boolean pointerFocused,
            boolean carriedStackActive,
            boolean exactCarriedOwner,
            boolean coordinateValid,
            double pointerX,
            double pointerY,
            int surfaceWidth,
            int surfaceHeight,
            boolean insideInteractionContent,
            ExternalScreenOverlayHandler.PointerButton button
    ) {
        if (button == null || (carriedStackActive && !exactCarriedOwner)) {
            return false;
        }
        if (pointerFocused) {
            return true;
        }
        boolean outsideDropButton =
                button == ExternalScreenOverlayHandler.PointerButton.PRIMARY
                        || button == ExternalScreenOverlayHandler.PointerButton.SECONDARY;
        return carriedStackActive
                && exactCarriedOwner
                && coordinateValid
                && outsideDropButton
                && !insideInteractionContent
                && isInsideSurface(pointerX, pointerY, surfaceWidth, surfaceHeight);
    }

    private static boolean isInsideSurface(
            double pointerX,
            double pointerY,
            int surfaceWidth,
            int surfaceHeight
    ) {
        return surfaceWidth > 0
                && surfaceHeight > 0
                && Double.isFinite(pointerX)
                && Double.isFinite(pointerY)
                && pointerX >= 0.0D
                && pointerY >= 0.0D
                && pointerX < surfaceWidth
                && pointerY < surfaceHeight;
    }
}
