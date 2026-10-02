package org.vivecraft.client_vr.gameplay.screenhandlers;

import org.junit.jupiter.api.Assertions;
import org.junit.jupiter.api.Test;

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;

class ExternalOverlayMipmapContractTest {
    private static final Path MAIN = Path.of("src", "main", "java");

    @Test
    void surfacePolicyControlsTargetAllocationAndBothGenerationPasses() throws IOException {
        String handler = source(
            "org/vivecraft/client_vr/gameplay/screenhandlers/ExternalScreenOverlayHandler.java");
        Assertions.assertTrue(handler.contains(
                "ClientDataHolderAccess.guiMipmaps() && handle.surface.usesMipmaps()"),
            "each external target must be able to disable mip allocation");
        Assertions.assertTrue(handler.contains(".withMipmaps(mipmapsEnabled)"));
        Assertions.assertTrue(handler.contains(
                "handle.framebufferMipmaps == mipmapsEnabled"),
            "changing the policy must recreate the target");

        String helper = source("org/vivecraft/client_vr/render/helpers/RenderHelper.java");
        Assertions.assertTrue(helper.contains("metrics == null || metrics.mipmapsEnabled()"),
            "screen rendering must not regenerate an opted-out target's mipmaps");
    }

    private static String source(String relative) throws IOException {
        return Files.readString(MAIN.resolve(relative));
    }
}
