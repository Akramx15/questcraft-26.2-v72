package org.questcraft.veq.client.gui;

/** Shared outside-click and passive-extension policy for embedded containers. */
final class VepExtendedContainerInput {
    private VepExtendedContainerInput() {
    }

    static boolean isOutside(double mouseX,
                             double mouseY,
                             int x,
                             int y,
                             int width,
                             int height) {
        return !contains(mouseX, mouseY, x, y, width, height);
    }

    static boolean retainVanillaOutside(boolean vanillaOutside,
                                        double mouseX,
                                        double mouseY,
                                        int interactionX,
                                        int interactionY,
                                        int interactionWidth,
                                        int interactionHeight) {
        return vanillaOutside && isOutside(
                mouseX,
                mouseY,
                interactionX,
                interactionY,
                interactionWidth,
                interactionHeight
        );
    }

    static CreativeOutsideDecision creativeOutsideDecision(boolean vanillaOutside,
                                                            double mouseX,
                                                            double mouseY,
                                                            int interactionX,
                                                            int interactionY,
                                                            int interactionWidth,
                                                            int interactionHeight) {
        boolean outside = retainVanillaOutside(
                vanillaOutside,
                mouseX,
                mouseY,
                interactionX,
                interactionY,
                interactionWidth,
                interactionHeight
        );
        // CreativeModeInventoryScreen.slotClicked reads its private latch on
        // release. It must match the narrowed result, not the native panel-only
        // result, or a passive VEQ extension can replay an outside drop.
        return new CreativeOutsideDecision(outside, outside);
    }

    static boolean isExtendedArea(double mouseX,
                                  double mouseY,
                                  int nativeX,
                                  int nativeY,
                                  int nativeWidth,
                                  int nativeHeight,
                                  int interactionX,
                                  int interactionY,
                                  int interactionWidth,
                                  int interactionHeight) {
        return contains(
                mouseX,
                mouseY,
                interactionX,
                interactionY,
                interactionWidth,
                interactionHeight
        ) && !contains(
                mouseX,
                mouseY,
                nativeX,
                nativeY,
                nativeWidth,
                nativeHeight
        );
    }

    static boolean contains(double mouseX,
                            double mouseY,
                            int x,
                            int y,
                            int width,
                            int height) {
        return width > 0
                && height > 0
                && Double.isFinite(mouseX)
                && Double.isFinite(mouseY)
                && mouseX >= x
                && mouseY >= y
                && mouseX < x + width
                && mouseY < y + height;
    }

    record CreativeOutsideDecision(boolean outside, boolean creativeLatch) {
    }
}
