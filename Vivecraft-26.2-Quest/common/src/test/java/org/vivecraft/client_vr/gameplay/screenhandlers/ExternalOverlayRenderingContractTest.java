package org.vivecraft.client_vr.gameplay.screenhandlers;

import org.junit.jupiter.api.Assertions;
import org.junit.jupiter.api.Test;

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;

class ExternalOverlayRenderingContractTest {
    private static final Path MAIN = Path.of("src", "main", "java");

    @Test
    void externalScreenFlushesDeferredElementsWithoutRestoringTheOrdinaryPlane() throws IOException {
        String helper = source("org/vivecraft/client_vr/render/helpers/GuiRenderHelper.java");
        int extractScreen = helper.indexOf("screen.extractRenderState(");
        int flushDeferred = helper.indexOf("graphics.extractDeferredElements(mouseX, mouseY, partialTick);");

        Assertions.assertTrue(extractScreen >= 0, "external screen state must be extracted");
        Assertions.assertTrue(flushDeferred > extractScreen,
            "tooltip/pre-edit elements must be flushed after screen extraction");
        Assertions.assertFalse(helper.contains("extractRenderStateWithTooltipAndSubtitles("),
            "the external path must not re-enter the ordinary full-screen renderer");
        Assertions.assertFalse(helper.contains("extractBackground("),
            "the external path must not restore the ordinary GUI background");
    }

    @Test
    void claimedScreenSuppressesOnlyTheOrdinaryCursorQuad() throws IOException {
        String pass = source("org/vivecraft/client_vr/render/helpers/VRPassHelper.java");
        int claimGuard = pass.indexOf("!ExternalScreenOverlayHandler.isCurrentGlobalScreenClaimed()");
        int cursorDraw = pass.indexOf("RenderHelper.drawMouseMenuQuad(");
        int overlayRecord = pass.indexOf("ExternalScreenOverlayHandler.render2D();");

        Assertions.assertTrue(claimGuard >= 0 && claimGuard < cursorDraw,
            "the global-screen claim must guard the ordinary GUI cursor draw");
        Assertions.assertTrue(cursorDraw < overlayRecord,
            "external surfaces must still be recorded after the ordinary cursor section");
    }

    @Test
    void surfaceMetricsCoverScreenAndCarriedRenderingAndAlwaysRestore() throws IOException {
        String handler = source(
            "org/vivecraft/client_vr/gameplay/screenhandlers/ExternalScreenOverlayHandler.java");
        int enter = handler.indexOf("RenderHelper.beginSurfaceGuiScope(");
        int renderSurface = handler.indexOf("handle.surface.renderSurface(", enter);
        int renderCarried = handler.indexOf("handle.surface.renderCarriedItem(", renderSurface);
        int finallyBlock = handler.indexOf("} finally {", renderCarried);
        int exit = handler.indexOf("handle.guiMetrics.exit();", finallyBlock);

        Assertions.assertTrue(enter >= 0 && enter < renderSurface,
            "surface metrics must be active before screen extraction starts");
        Assertions.assertTrue(renderSurface < renderCarried,
            "the carried item must render inside the same surface scope");
        Assertions.assertTrue(renderCarried < finallyBlock && finallyBlock < exit,
            "surface metrics must restore from finally after the carried pass");

        String metrics = source("org/vivecraft/client_vr/render/helpers/SurfaceGuiMetrics.java");
        Assertions.assertTrue(metrics.contains("guiScaleState.setGuiScale(this.rasterScale);"));
        Assertions.assertTrue(metrics.contains("guiScaleState.setMaxGuiScale(this.rasterScale);"));
        Assertions.assertTrue(metrics.contains(
            "scopedGuiScaleState.setGuiScale(this.previousGuiHandlerScale);"));
        Assertions.assertTrue(metrics.contains(
            "scopedGuiScaleState.setMaxGuiScale(this.previousGuiHandlerMaxScale);"));
    }

    @Test
    void retainedSurfaceCanSkipOnlyAfterOneCompleteRender() throws IOException {
        String handler = source(
            "org/vivecraft/client_vr/gameplay/screenhandlers/ExternalScreenOverlayHandler.java");
        int redrawDecision = handler.indexOf("handle.surface.shouldRedraw(frameTimeNanos, cursor)");
        int completedGuard = handler.indexOf("handle.hasRendered && !surfaceWantsRedraw", redrawDecision);
        int clear = handler.indexOf("clearColorAndDepthTextures(", completedGuard);
        int renderSurface = handler.indexOf("handle.surface.renderSurface(", clear);
        int renderCarried = handler.indexOf("handle.surface.renderCarriedItem(", renderSurface);
        int completed = handler.indexOf("handle.hasRendered = true;", renderCarried);

        Assertions.assertTrue(redrawDecision >= 0 && redrawDecision < completedGuard,
            "the surface policy must run before the retained-target guard");
        Assertions.assertTrue(completedGuard < clear,
            "a skipped retained surface must avoid framebuffer clear and extraction");
        Assertions.assertTrue(clear < renderSurface && renderSurface < renderCarried
                && renderCarried < completed,
            "a target becomes reusable only after both render passes complete");
        Assertions.assertTrue(handler.contains(
                "default boolean shouldRedraw(long frameTimeNanos, RenderCursor cursor)"));
        Assertions.assertTrue(handler.contains("return true;"),
            "surfaces must preserve full-rate redraw unless they explicitly opt in");

        int destroy = handler.indexOf("private void destroyFramebuffer()");
        int reset = handler.indexOf("this.hasRendered = false;", destroy);
        Assertions.assertTrue(destroy >= 0 && reset > destroy,
            "framebuffer destruction/resize must invalidate retained pixels");

    }

    @Test
    void windowAndRenderHelpersPreferActiveSurfaceMetricsWithoutChangingFallbacks() throws IOException {
        String window = source("org/vivecraft/mixin/client_vr/blaze3d/platform/WindowVRMixin.java");
        Assertions.assertTrue(window.contains("metrics.physicalWidth()"));
        Assertions.assertTrue(window.contains("metrics.physicalHeight()"));
        Assertions.assertTrue(window.contains("metrics.logicalWidth()"));
        Assertions.assertTrue(window.contains("metrics.logicalHeight()"));
        Assertions.assertTrue(window.contains("metrics.rasterScale()"));
        Assertions.assertTrue(window.contains(": GuiHandler.GUI_WIDTH"),
            "ordinary VR screen width fallback must remain unchanged");
        Assertions.assertTrue(window.contains(": GuiHandler.GUI_HEIGHT"),
            "ordinary VR screen height fallback must remain unchanged");
        Assertions.assertTrue(window.contains("GuiHandler.SCALED_WIDTH_MAX : GuiHandler.SCALED_WIDTH"),
            "ordinary/HUD logical width fallback must remain unchanged");
        Assertions.assertTrue(window.contains("GuiHandler.SCALED_HEIGHT_MAX : GuiHandler.SCALED_HEIGHT"),
            "ordinary/HUD logical height fallback must remain unchanged");

        String helper = source("org/vivecraft/client_vr/render/helpers/RenderHelper.java");
        int activeScale = helper.indexOf("metrics != null ? metrics.rasterScale()");
        int maxScale = helper.indexOf("maxGuiScale ? GuiHandler.GUI_SCALE_FACTOR_MAX", activeScale);
        int restore = helper.indexOf("GuiHandler.GUI_SCALE_FACTOR = backupGuiScale;", maxScale);
        Assertions.assertTrue(activeScale >= 0 && activeScale < maxScale,
            "an active surface raster scale must override the ordinary max GUI scale");
        Assertions.assertTrue(restore > helper.indexOf("} finally {", maxScale),
            "RenderHelper must restore its scissor scale from finally");
        Assertions.assertTrue(helper.contains(
            "int guiScale = metrics != null ? metrics.rasterScale() : MC.getWindow().getGuiScale();"),
            "the pointer must use the same raster scale as projection and scissor");
    }

    private static String source(String relative) throws IOException {
        return Files.readString(MAIN.resolve(relative));
    }
}
