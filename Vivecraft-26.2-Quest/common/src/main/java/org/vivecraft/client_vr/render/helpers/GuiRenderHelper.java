package org.vivecraft.client_vr.render.helpers;

import net.minecraft.client.Minecraft;
import net.minecraft.client.gui.GuiGraphicsExtractor;
import net.minecraft.client.gui.render.GuiRenderer;
import net.minecraft.client.gui.screens.Screen;
import net.minecraft.client.renderer.state.gui.GuiRenderState;
import net.minecraft.util.profiling.Profiler;
import org.vivecraft.mixin.client_vr.renderer.GameRendererAccessor;

public class GuiRenderHelper {


    public static GuiGraphicsExtractor getGuiGraphics() {
        GuiRenderState guiRenderState = ((GameRendererAccessor) Minecraft.getInstance().gameRenderer).getGameRenderState().guiRenderState;
        guiRenderState.reset();
        return new GuiGraphicsExtractor(Minecraft.getInstance(), guiRenderState, 0, 0);
    }

    public static void renderScreen(Screen screen) {
        renderScreen(screen, 0, 0);
    }

    public static void renderScreen(Screen screen, int mouseX, int mouseY) {
        GuiGraphicsExtractor graphics = getGuiGraphics();
        float partialTick = Minecraft.getInstance().getDeltaTracker().getRealtimeDeltaTicks();
        Profiler.get().push("extract");
        screen.extractRenderState(
            graphics,
            mouseX,
            mouseY,
            partialTick);
        // Screen#extractRenderState only queues tooltip/pre-edit content. The
        // ordinary GUI plane normally flushes it from
        // extractRenderStateWithTooltipAndSubtitles, but claimed screens skip
        // that path and are recorded here instead. Flush only the deferred
        // elements: do not restore the ordinary screen background or render
        // the screen a second time.
        graphics.extractDeferredElements(mouseX, mouseY, partialTick);
        Profiler.get().pop();
        finish();
    }

    public static void finish() {
        Profiler.get().push("render");
        GuiRenderer guiRenderer = ((GameRendererAccessor) Minecraft.getInstance().gameRenderer).getGuiRenderer();
        guiRenderer.render();
        guiRenderer.endFrame();
        Profiler.get().pop();
    }
}
