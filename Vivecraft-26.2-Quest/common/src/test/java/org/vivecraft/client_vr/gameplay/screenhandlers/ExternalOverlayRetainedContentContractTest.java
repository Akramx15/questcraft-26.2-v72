package org.vivecraft.client_vr.gameplay.screenhandlers;

import org.junit.jupiter.api.Assertions;
import org.junit.jupiter.api.Test;

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;

class ExternalOverlayRetainedContentContractTest {
    private static final Path MAIN = Path.of("src", "main", "java");

    @Test
    void retainedSurfaceOwnsASeparateNoMipContentTarget() throws IOException {
        String handler = source();
        int policy = handler.indexOf("handle.surface.usesRetainedContentTarget()");
        int create = handler.indexOf("\"External Screen Overlay Content: \"", policy);
        int noMips = handler.indexOf(".withMipmaps(false)", create);

        Assertions.assertTrue(policy >= 0 && policy < create,
            "retained-content policy must control allocation of the second target");
        Assertions.assertTrue(create < noMips,
            "the retained content target must not allocate a mip chain");
        Assertions.assertTrue(handler.contains(
                "handle.contentGuiMetrics.configure(width, height, scaledWidth, scaledHeight, false);"),
            "base Screen extraction must also suppress mip generation");
        Assertions.assertTrue(handler.contains(
                "retainedContent ? false : mipmapsEnabled"),
            "retained presentation helpers must defer intermediate mip generation");
    }

    @Test
    void failedBaseDrawRetriesAndCountersOnlyCompleteWork() throws IOException {
        String handler = source();
        int method = handler.indexOf("private static void renderRetainedSurface(");
        int requested = handler.indexOf(
            "if (!handle.contentHasRendered || surfaceWantsRedraw)", method);
        int draw = handler.indexOf("handle.surface.renderSurface(contentTarget, cursor);", requested);
        int callback = handler.indexOf("handle.surface.redrawCompleted(frameTimeNanos, cursor);", draw);
        int completed = handler.indexOf("handle.contentHasRendered = true;", callback);
        int counter = handler.indexOf("handle.contentRenderCount++;", completed);
        int finallyBlock = handler.indexOf("} finally {", counter);

        Assertions.assertTrue(method >= 0 && method < requested && requested < draw);
        Assertions.assertTrue(draw < callback && callback < completed && completed < counter,
            "dirty snapshot and content counter must commit only after a complete base draw");
        Assertions.assertTrue(counter < finallyBlock,
            "the content GUI scope must still restore after an exception");
    }

    @Test
    void everyPresentationStartsFromCleanContentSoDynamicPixelsCannotGhost() throws IOException {
        String handler = source();
        int method = handler.indexOf("private static void renderRetainedSurface(");
        int presentation = handler.indexOf(
            "minecraft.gameRenderer.mainRenderTarget = presentationTarget;", method);
        int clear = handler.indexOf("clearTarget(presentationTarget);", presentation);
        int blit = handler.indexOf(
            "ShaderHelper.blitRgba(contentTarget, presentationTarget);", clear);
        int dynamic = handler.indexOf(
            "handle.surface.renderCarriedItem(presentationTarget, cursor);", blit);
        int finalMips = handler.indexOf(
            "GraphicsHelper.INSTANCE.genMipmaps(presentationTarget.getColorTexture());", dynamic);
        int counter = handler.indexOf("handle.presentationRenderCount++;", finalMips);

        Assertions.assertTrue(presentation >= 0 && presentation < clear);
        Assertions.assertTrue(clear < blit && blit < dynamic && dynamic < finalMips
                && finalMips < counter,
            "each frame must erase old pointer pixels, restore base content, then draw live decorations");

        int retainedDispatch = handler.indexOf("if (handle.contentFramebuffer != null)");
        int retainedCall = handler.indexOf("renderRetainedSurface(", retainedDispatch);
        int skip = handler.indexOf("handle.hasRendered && !surfaceWantsRedraw", retainedCall);
        Assertions.assertTrue(retainedDispatch >= 0 && retainedDispatch < retainedCall && retainedCall < skip,
            "retained surfaces must compose before the single-target skip guard");
    }

    @Test
    void retainedBaseCopyWritesStraightRgbaWithoutBlending() throws IOException {
        String shaders = Files.readString(MAIN.resolve(
            "org/vivecraft/client_vr/render/VRShaders.java"));
        String helper = Files.readString(MAIN.resolve(
            "org/vivecraft/client_vr/render/helpers/ShaderHelper.java"));
        String fragment = Files.readString(Path.of("src", "main", "resources", "assets",
            "vivecraft", "shaders", "core", "blit_vr.fsh"));

        int pipeline = shaders.indexOf("BLIT_VR_RGBA_PIPELINE");
        int writeAll = shaders.indexOf("ColorTargetState.WRITE_ALL", pipeline);
        int pipelineEnd = shaders.indexOf(".build();", pipeline);
        Assertions.assertTrue(pipeline >= 0 && pipeline < writeAll && writeAll < pipelineEnd,
            "retained copy pipeline must write alpha as well as RGB");
        Assertions.assertFalse(shaders.substring(pipeline, pipelineEnd).contains("BlendFunction"),
            "retained copy pipeline must not alpha-blend or premultiply the base surface");

        int method = helper.indexOf("void blitRgba(");
        int selected = helper.indexOf("VRShaders.BLIT_VR_RGBA_PIPELINE", method);
        Assertions.assertTrue(method >= 0 && method < selected,
            "the dedicated retained copy helper must select the RGBA pipeline");
        Assertions.assertTrue(fragment.contains(
                "fragColor = texture(DiffuseSampler, texCoordinates.st);"),
            "the RGBA copy shader must pass through sampled alpha unchanged");
    }

    @Test
    void resizeAndShutdownDestroyBothTargetsAndInvalidateTheirFrames() throws IOException {
        String handler = source();
        int ensure = handler.indexOf("private static void ensureFramebuffer(");
        int recreate = handler.indexOf("handle.destroyFramebuffer();", ensure);
        int resize = handler.indexOf("handle.surface.resize(scaledWidth, scaledHeight);", recreate);
        int destroy = handler.indexOf("private void destroyFramebuffer()");
        int presentation = handler.indexOf("this.framebuffer.destroyBuffers();", destroy);
        int content = handler.indexOf("this.contentFramebuffer.destroyBuffers();", presentation);
        int presentationReset = handler.indexOf("this.hasRendered = false;", content);
        int contentReset = handler.indexOf("this.contentHasRendered = false;", presentationReset);

        Assertions.assertTrue(ensure >= 0 && ensure < recreate && recreate < resize,
            "a size or policy change must retire both old targets before notifying the surface");
        Assertions.assertTrue(destroy >= 0 && destroy < presentation && presentation < content,
            "lifecycle teardown must release presentation and retained content targets");
        Assertions.assertTrue(content < presentationReset && presentationReset < contentReset,
            "resize/teardown must force both layers to render again");
    }

    private static String source() throws IOException {
        return Files.readString(MAIN.resolve(
            "org/vivecraft/client_vr/gameplay/screenhandlers/ExternalScreenOverlayHandler.java"));
    }
}
