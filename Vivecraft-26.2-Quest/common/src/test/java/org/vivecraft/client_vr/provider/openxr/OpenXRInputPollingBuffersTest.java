package org.vivecraft.client_vr.provider.openxr;

import org.junit.jupiter.api.Assertions;
import org.junit.jupiter.api.Test;

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;

class OpenXRInputPollingBuffersTest {

    @Test
    void pollingStructsAreAllocatedOnceAndReused() throws IOException {
        String buffers = Files.readString(Path.of(
            "src/main/java/org/vivecraft/client_vr/provider/openxr/OpenXRInputPollingBuffers.java"));
        String provider = Files.readString(Path.of(
            "src/main/java/org/vivecraft/client_vr/provider/openxr/MCOpenXR.java"));

        Assertions.assertEquals(1, occurrences(buffers, "XrActionStateGetInfo.calloc()"));
        Assertions.assertEquals(1, occurrences(buffers, "XrActionStateBoolean.calloc()"));
        Assertions.assertEquals(1, occurrences(buffers, "XrActionStateFloat.calloc()"));
        Assertions.assertEquals(1, occurrences(buffers, "XrActionStateVector2f.calloc()"));
        Assertions.assertEquals(1, occurrences(buffers, "XrActionStatePose.calloc()"));
        Assertions.assertEquals(1, occurrences(buffers, "this.vector2State.currentState()"));
        Assertions.assertTrue(provider.contains("this.inputPollingBuffers.prepare("));
        Assertions.assertTrue(provider.contains("private static final ControllerType[] CONTROLLERS"));
        Assertions.assertFalse(provider.contains("for (ControllerType controller : ControllerType.values())"));
    }

    private static int occurrences(String value, String needle) {
        return (value.length() - value.replace(needle, "").length()) / needle.length();
    }
}
