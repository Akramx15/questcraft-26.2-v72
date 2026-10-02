package org.vivecraft.client_vr.provider.openxr;

import org.junit.jupiter.api.Assertions;
import org.junit.jupiter.api.Test;

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;

class OpenXRHandednessSourceTest {
    @Test
    void actionSpacesRemainPhysicalAndHapticsAreNotReversedTwice() throws IOException {
        String provider = Files.readString(Path.of(
            "src/main/java/org/vivecraft/client_vr/provider/openxr/MCOpenXR.java"));
        String haptics = Files.readString(Path.of(
            "src/main/java/org/vivecraft/client_vr/provider/openxr/OpenXRHapticScheduler.java"));

        Assertions.assertFalse(provider.contains("XrSpace temp = this.gripSpace"));
        Assertions.assertFalse(provider.contains("this.gripSpace[RIGHT_CONTROLLER] = this.gripSpace[LEFT_CONTROLLER]"));
        Assertions.assertTrue(provider.contains("OpenXRHandedness.physicalIndex"));
        Assertions.assertTrue(provider.contains("this.aimToGripTransform[controllerIndex]"));
        Assertions.assertFalse(haptics.contains("vrSettings.reverseHands"));
    }
}
