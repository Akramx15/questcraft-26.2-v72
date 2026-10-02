package org.questcraft.veq.client.gui;

import org.jetbrains.annotations.Nullable;

/** Pure geometry port from VEP's VRInvEffectInvScreen. */
public final class VepEffectLayout {
    private VepEffectLayout() {
    }

    public static @Nullable Bounds calculate(int leftPos,
                                             int topPos,
                                             int imageWidth,
                                             int screenWidth,
                                             int visibleEffectCount) {
        if (visibleEffectCount <= 0) {
            return null;
        }
        int startX = leftPos + imageWidth + 2;
        int availableWidth = screenWidth - startX;
        if (availableWidth < 32) {
            return null;
        }
        int width = availableWidth >= 120 ? 120 : 32;
        int rowSpacing = visibleEffectCount > 5 ? 132 / (visibleEffectCount - 1) : 33;
        return new Bounds(startX, topPos, width,
                32 + (visibleEffectCount - 1) * rowSpacing);
    }

    public record Bounds(int x, int y, int width, int height) {
    }
}
