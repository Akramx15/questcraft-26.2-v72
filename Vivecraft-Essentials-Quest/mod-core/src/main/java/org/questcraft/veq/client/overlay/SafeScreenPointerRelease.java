package org.questcraft.veq.client.overlay;

import net.minecraft.client.gui.screens.Screen;
import net.minecraft.client.gui.screens.inventory.AbstractContainerScreen;
import net.minecraft.client.input.MouseButtonEvent;
import net.minecraft.client.input.MouseButtonInfo;
import org.vivecraft.client_vr.gameplay.screenhandlers.ExternalScreenOverlayHandler;

/** Releases or cancels only the exact screen that accepted a pointer press. */
final class SafeScreenPointerRelease {
    static final double CANCEL_COORDINATE = -10_000.0D;

    private SafeScreenPointerRelease() {
    }

    static void release(Screen screen,
                        ExternalScreenOverlayHandler.PointerButton button,
                        double x,
                        double y) {
        screen.mouseReleased(event(x, y, button));
    }

    static void cancel(Screen screen,
                       ExternalScreenOverlayHandler.PointerButton button) {
        MouseButtonEvent event = event(CANCEL_COORDINATE, CANCEL_COORDINATE, button);
        if (screen instanceof VeqOwnedPointerCancellation ownedCancellation) {
            ownedCancellation.veq$cancelOwnedPointerGesture();
        }
        if (screen instanceof ContainerPointerCancellation cancellation) {
            cancellation.veq$cancelPointerGesture(event);
            return;
        }
        if (screen instanceof AbstractContainerScreen<?>) {
            // A missing required mixin must fail closed: a normal off-screen
            // release can become slot -999 and throw/drop the carried stack.
            return;
        }
        screen.mouseReleased(event);
    }

    private static MouseButtonEvent event(
            double x,
            double y,
            ExternalScreenOverlayHandler.PointerButton button
    ) {
        return new MouseButtonEvent(
                x,
                y,
                new MouseButtonInfo(button.mouseButton(), 0)
        );
    }
}
