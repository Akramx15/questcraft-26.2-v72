package org.vivecraft.client_vr.render.helpers.graphics;

import org.junit.jupiter.api.Assertions;
import org.junit.jupiter.api.Test;

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;

class VulkanExternalImageLayoutContractTest {

    @Test
    void acquiredOpenXRColorImagePreservesRuntimeLayoutBeforeCopy() throws IOException {
        String source = Files.readString(Path.of(
            "src/main/java/org/vivecraft/client_vr/render/helpers/graphics/VulkanHelper.java"));
        String copy = between(source, "public void copyToExternalImage(", "public void genMipmaps(");

        Assertions.assertTrue(copy.contains(
            "VK10.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL, VK10.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL,"));
        Assertions.assertFalse(copy.contains("VK10.VK_IMAGE_LAYOUT_UNDEFINED"));
        Assertions.assertTrue(copy.contains(
            "VK10.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL, VK10.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL,"));
    }

    private static String between(String source, String startNeedle, String endNeedle) {
        int start = source.indexOf(startNeedle);
        int end = source.indexOf(endNeedle, start + startNeedle.length());
        Assertions.assertTrue(start >= 0, "missing source marker: " + startNeedle);
        Assertions.assertTrue(end > start, "missing source marker: " + endNeedle);
        return source.substring(start, end);
    }
}
