package org.questcraft.veq.client.overlay;

import com.mojang.blaze3d.pipeline.RenderTarget;
import net.minecraft.client.Minecraft;
import net.minecraft.client.gui.GuiGraphicsExtractor;
import net.minecraft.client.gui.screens.inventory.AbstractContainerScreen;
import org.vivecraft.client_vr.ClientDataHolderVR;
import org.vivecraft.client_vr.gameplay.screenhandlers.ExternalScreenOverlayHandler;
import org.vivecraft.client_vr.gameplay.screenhandlers.GuiHandler;
import org.vivecraft.client_vr.render.helpers.GuiRenderHelper;
import org.vivecraft.client_vr.render.helpers.RenderHelper;
import org.vivecraft.client_vr.render.helpers.SurfaceGuiMetrics;
import org.vivecraft.client_vr.render.helpers.graphics.GraphicsHelper;

/** Shared controller-pointer compositor for VEQ-owned external surfaces. */
public final class VepSurfacePointerRenderer {
    private VepSurfacePointerRenderer() {
    }

    public static void render(GuiGraphicsExtractor graphics,
                              int mouseX,
                              int mouseY,
                              int surfaceWidth,
                              int surfaceHeight) {
        if (isInsideSurface(mouseX, mouseY, surfaceWidth, surfaceHeight)) {
            // Do not clamp to panel/content bounds: the same coordinates drive
            // hover and an owned drag after its ray leaves the active control.
            RenderHelper.drawMouseMenuQuad(graphics, mouseX, mouseY);
        }
    }

    /**
     * Adds the contextual pointer to the currently bound surface target, then
     * re-extracts Vanilla's carried item in the following GUI stratum. The
     * external-surface engine invokes this from that surface's carried-item
     * pass, so no global GUI cursor or additional OpenXR layer is involved.
     */
    public static void renderPointerWithCarriedAbove(
            RenderTarget target,
            AbstractContainerScreen<?> screen,
            ExternalScreenOverlayHandler.RenderCursor cursor,
            int surfaceWidth,
            int surfaceHeight,
            ExternalScreenOverlayHandler.SurfaceBounds visibleBounds
    ) {
        if (target == null || screen == null) {
            return;
        }
        CursorPosition pointerPosition = cursorPosition(cursor, surfaceWidth, surfaceHeight);
        int mouseX = cursor != null && cursor.valid()
                ? screenMouseCoordinate(cursor.x())
                : -10_000;
        int mouseY = cursor != null && cursor.valid()
                ? screenMouseCoordinate(cursor.y())
                : -10_000;
        if (!screen.getMenu().getCarried().isEmpty() && cursor != null && cursor.valid()) {
            ExternalScreenOverlayHandler.ResolvedSurfaceBounds crop =
                    (visibleBounds == null
                            ? ExternalScreenOverlayHandler.SurfaceBounds.full()
                            : visibleBounds).resolve(surfaceWidth, surfaceHeight);
            mouseX = CarriedItemPosition.clamp(mouseX, crop.x(), crop.width());
            mouseY = CarriedItemPosition.clamp(mouseY, crop.y(), crop.height());
        }
        int previousScale = GuiHandler.GUI_SCALE_FACTOR;
        GuiHandler.GUI_SCALE_FACTOR = GuiHandler.GUI_SCALE_FACTOR_MAX;
        try {
            GuiGraphicsExtractor graphics = GuiRenderHelper.getGuiGraphics();
            if (pointerPosition != null) {
                render(graphics, pointerPosition.x(), pointerPosition.y(),
                        surfaceWidth, surfaceHeight);
            }
            // AbstractContainerScreen advances to a new stratum before drawing,
            // guaranteeing that the carried stack remains above the '+' cursor.
            screen.extractCarriedItem(graphics, mouseX, mouseY);
            float partialTick = Minecraft.getInstance()
                    .getDeltaTracker()
                    .getRealtimeDeltaTicks();
            graphics.extractDeferredElements(mouseX, mouseY, partialTick);
            GuiRenderHelper.finish();
        } finally {
            GuiHandler.GUI_SCALE_FACTOR = previousScale;
        }
        SurfaceGuiMetrics metrics = SurfaceGuiMetrics.active();
        if (ClientDataHolderVR.getInstance().vrSettings.guiMipmaps
                && (metrics == null || metrics.mipmapsEnabled())) {
            GraphicsHelper.INSTANCE.genMipmaps(target.getColorTexture());
        }
    }

    public static boolean canRender(ExternalScreenOverlayHandler.RenderCursor cursor,
                                    int surfaceWidth,
                                    int surfaceHeight) {
        return cursor != null
                && cursor.valid()
                && isInsideSurface(cursor.x(), cursor.y(), surfaceWidth, surfaceHeight);
    }

    public static boolean canReceiveInput(ExternalScreenOverlayHandler.RenderCursor cursor,
                                          int surfaceWidth,
                                          int surfaceHeight) {
        return cursor != null
                && cursor.valid()
                && cursor.focused()
                && isInsideSurface(cursor.x(), cursor.y(), surfaceWidth, surfaceHeight);
    }

    public static boolean isInsideUnitUv(double u, double v) {
        return Double.isFinite(u)
                && Double.isFinite(v)
                && u >= 0.0D
                && v >= 0.0D
                && u < 1.0D
                && v < 1.0D;
    }

    public static boolean isInsideSurface(double mouseX,
                                          double mouseY,
                                          int surfaceWidth,
                                          int surfaceHeight) {
        return surfaceWidth > 0
                && surfaceHeight > 0
                && Double.isFinite(mouseX)
                && Double.isFinite(mouseY)
                && mouseX >= 0
                && mouseY >= 0
                && mouseX < surfaceWidth
                && mouseY < surfaceHeight;
    }

    static int screenMouseCoordinate(double coordinate) {
        double floored = Math.floor(coordinate);
        if (!Double.isFinite(floored)
                || floored < Integer.MIN_VALUE
                || floored > Integer.MAX_VALUE) {
            return -10_000;
        }
        return (int) floored;
    }

    private static CursorPosition cursorPosition(
            ExternalScreenOverlayHandler.RenderCursor cursor,
            int surfaceWidth,
            int surfaceHeight
    ) {
        if (cursor == null || !cursor.valid()
                || !isInsideSurface(cursor.x(), cursor.y(), surfaceWidth, surfaceHeight)) {
            return null;
        }
        return new CursorPosition(
                screenMouseCoordinate(cursor.x()),
                screenMouseCoordinate(cursor.y())
        );
    }

    private record CursorPosition(int x, int y) {
    }
}
