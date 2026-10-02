package org.vivecraft.client_vr.provider.openxr;

import org.junit.jupiter.api.Assertions;
import org.junit.jupiter.api.Test;

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;

class QuestOpenXRBackgroundIntegrationContractTest {

    private static String source(String relativePath) throws IOException {
        return Files.readString(Path.of("src/main/java").resolve(relativePath));
    }

    @Test
    void stoppedSessionParksOnlyAfterOpenXREventPolling() throws IOException {
        String provider = source("org/vivecraft/client_vr/provider/openxr/MCOpenXR.java");
        String poll = between(provider, "public void poll(long frameIndex)", "private void updatePose()");
        assertOrdered(poll, "this.pollVREvents();", "this.updatePose();");
        Assertions.assertFalse(poll.contains("parkNanos"),
            "the active OpenXR poll/frame method must not sleep");

        String mixin = source("org/vivecraft/mixin/client_vr/MinecraftVRMixin.java");
        String pollHook = between(mixin, "private void vivecraft$poll()", "private void vivecraft$preTickTasks");
        assertOrdered(pollHook, ".vr.poll(", "openxr.throttleStoppedSession();");
        Assertions.assertTrue(provider.contains("nanos -> LockSupport.parkNanos(this, nanos)"));
        Assertions.assertFalse(provider.contains("Thread.sleep"));
    }

    @Test
    void throttleTransitionLoggingIsLatchedAndNeverPerPoll() throws IOException {
        String provider = source("org/vivecraft/client_vr/provider/openxr/MCOpenXR.java");
        String throttle = between(
            provider, "public void throttleStoppedSession()", "public boolean shouldSkipHeavyRender()");

        Assertions.assertTrue(throttle.contains("if (!this.stoppedSessionThrottleActive)"));
        Assertions.assertTrue(throttle.contains("this.stoppedSessionThrottleTransition++"));
        Assertions.assertTrue(throttle.contains("stopped-session throttle entered transition={}"));
        Assertions.assertTrue(throttle.contains("stopped-session throttle resumed transition={}"));
        Assertions.assertTrue(throttle.contains("this.stoppedSessionThrottleActive = false"));
        Assertions.assertEquals(1, occurrences(throttle, "stopped-session throttle entered transition={}"));
        Assertions.assertEquals(1, occurrences(throttle, "stopped-session throttle resumed transition={}"));
    }

    @Test
    void shouldRenderFalseCompletesAZeroLayerFrameWithoutHeavyRender() throws IOException {
        String provider = source("org/vivecraft/client_vr/provider/openxr/MCOpenXR.java");
        String updatePose = between(provider, "private void updatePose()", "public void readNewData");
        assertOrdered(updatePose, "XR10.xrWaitFrame(", "this.shouldRender = frameState.shouldRender();");
        assertOrdered(updatePose, "this.shouldRender = frameState.shouldRender();", "XR10.xrBeginFrame(");

        String mixin = source("org/vivecraft/mixin/client_vr/MinecraftVRMixin.java");
        String renderHead = between(mixin, "private void vivecraft$backupPoll", "private Object vivecraft$noVsyncInVR");
        assertOrdered(renderHead, "this.vivecraft$poll();", "openxr.shouldSkipHeavyRender()");
        assertOrdered(renderHead, "openxr.shouldSkipHeavyRender()", "dataHolder.vrRenderer.endFrame();");
        assertOrdered(renderHead, "dataHolder.vrRenderer.endFrame();", "ci.cancel();");

        String renderer = source(
            "org/vivecraft/client_vr/provider/openxr/OpenXRStereoRenderer.java");
        String endFrame = between(renderer, "public void endFrame()", "private Throwable releaseWaitedImages");
        Assertions.assertTrue(endFrame.contains("boolean completePair"));
        Assertions.assertTrue(endFrame.contains("failure = this.releaseWaitedImages(stack, failure);"));
        Assertions.assertTrue(endFrame.contains("PointerBuffer layers = null;"));
        Assertions.assertTrue(endFrame.contains(".layers(layers)"),
            "xrEndFrame must receive null layers when shouldRender=false");
        assertOrdered(endFrame, "failure = this.releaseWaitedImages(stack, failure);", "XR10.xrEndFrame(");
        Assertions.assertFalse(endFrame.substring(endFrame.indexOf("finally")).contains(
            "this.imageAcquired[0] = false"),
            "frame cleanup must not forget an image whose release failed");
    }

    @Test
    void acquireTracksOwnershipBeforeWaitAndCleansCompletedEyesOnFailure() throws IOException {
        String renderer = source(
            "org/vivecraft/client_vr/provider/openxr/OpenXRStereoRenderer.java");
        String acquire = between(renderer, "private void acquireSwapchainImages()", "public Matrix4f getCachedProjectionMatrix");

        assertOrdered(acquire, "this.imageAcquired[eye] = true;", "XR10.xrWaitSwapchainImage(");
        assertOrdered(acquire, "XR10.xrWaitSwapchainImage(", "this.imageWaited[eye] = true;");
        assertOrdered(acquire, "catch (Throwable throwable)", "this.releaseWaitedImages(stack, failure)");
        assertOrdered(acquire, "this.releaseWaitedImages(stack, failure)", "this.endFrame();");
        assertOrdered(acquire, "this.endFrame();", "rethrow(failure);");
    }

    @Test
    void protectionDoesNotDisableVrOrPauseTheIntegratedServer() throws IOException {
        String provider = source("org/vivecraft/client_vr/provider/openxr/MCOpenXR.java");
        String protection = between(
            provider, "public void throttleStoppedSession()", "public ControllerType getOriginControllerType");
        String policy = source(
            "org/vivecraft/client_vr/provider/openxr/QuestOpenXRBackgroundPolicy.java");
        String mixin = source("org/vivecraft/mixin/client_vr/MinecraftVRMixin.java");
        String renderHead = between(mixin, "private void vivecraft$backupPoll", "private Object vivecraft$noVsyncInVR");
        String combined = protection + policy + renderHead;

        Assertions.assertFalse(combined.contains("VR_ENABLED ="));
        Assertions.assertFalse(combined.contains("pauseGame"));
        Assertions.assertFalse(combined.contains("stopServer"));
        Assertions.assertFalse(combined.contains("Thread.sleep"));
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
        Assertions.assertTrue(secondIndex > firstIndex,
            second + " must follow " + first);
    }

    private static int occurrences(String source, String needle) {
        int count = 0;
        int offset = 0;
        while ((offset = source.indexOf(needle, offset)) >= 0) {
            count++;
            offset += needle.length();
        }
        return count;
    }
}
