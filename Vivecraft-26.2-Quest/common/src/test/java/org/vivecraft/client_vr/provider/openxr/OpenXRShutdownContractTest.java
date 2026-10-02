package org.vivecraft.client_vr.provider.openxr;

import org.junit.jupiter.api.Assertions;
import org.junit.jupiter.api.Test;

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;

class OpenXRShutdownContractTest {

    @Test
    void hapticsStopBeforeXrHandlesAndBaseCleanupRunsInFinally() throws IOException {
        String provider = Files.readString(Path.of(
            "src/main/java/org/vivecraft/client_vr/provider/openxr/MCOpenXR.java"));
        String destroy = between(provider, "public void destroy()", "protected ControllerType findActiveBindingControllerType");

        assertOrdered(destroy, "this.hapticScheduler.shutdownNow();", "XR10.xrDestroyActionSet(");
        assertOrdered(destroy, "XR10.xrDestroyInstance(", "finally");
        assertOrdered(destroy, "finally", "super.destroy();");
    }

    @Test
    void baseProviderAlsoClosesHapticsBeforeOtherCleanup() throws IOException {
        String provider = Files.readString(Path.of(
            "src/main/java/org/vivecraft/client_vr/provider/MCVR.java"));
        String destroy = between(provider, "public void destroy()", "public void triggerHapticPulse");

        assertOrdered(destroy, "this.hapticScheduler.shutdownNow();", "this.oscTrackers.stop();");
        assertOrdered(destroy, "this.oscTrackers.stop();", "ME = null;");
    }

    private static String between(String source, String startNeedle, String endNeedle) {
        int start = source.indexOf(startNeedle);
        int end = source.indexOf(endNeedle, start + startNeedle.length());
        Assertions.assertTrue(start >= 0, "missing source marker: " + startNeedle);
        Assertions.assertTrue(end > start, "missing source marker: " + endNeedle);
        return source.substring(start, end);
    }

    private static void assertOrdered(String source, String first, String second) {
        int firstIndex = source.indexOf(first);
        int secondIndex = source.indexOf(second);
        Assertions.assertTrue(firstIndex >= 0, "missing source marker: " + first);
        Assertions.assertTrue(secondIndex > firstIndex, second + " must follow " + first);
    }
}
