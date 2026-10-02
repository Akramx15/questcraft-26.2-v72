package org.vivecraft.client_vr.provider.openxr;

import net.minecraft.network.chat.Component;
import org.junit.jupiter.api.Assertions;
import org.junit.jupiter.api.Test;
import org.vivecraft.client_vr.render.RenderConfigException;

import java.util.ArrayList;
import java.util.List;

class OpenXRStereoRendererStateTest {

    @Test
    void releaseFailureForOneEyeDoesNotPreventReleasingTheOther() {
        boolean[] acquired = {true, true};
        boolean[] waited = {true, true};
        List<Integer> attempts = new ArrayList<>();
        RenderConfigException primary = failure("copy failed");
        RenderConfigException releaseFailure = failure("left release failed");

        Throwable result = OpenXRStereoRenderer.releaseWaitedImages(
            acquired, waited, eye -> {
                attempts.add(eye);
                if (eye == 0) {
                    throw releaseFailure;
                }
            }, primary);

        Assertions.assertSame(primary, result);
        Assertions.assertEquals(List.of(0, 1), attempts);
        Assertions.assertArrayEquals(new boolean[]{true, false}, acquired);
        Assertions.assertArrayEquals(new boolean[]{true, false}, waited);
        Assertions.assertArrayEquals(new Throwable[]{releaseFailure}, primary.getSuppressed());
    }

    @Test
    void successfulCleanupPreservesTheOriginalCopyFailure() {
        boolean[] acquired = {true, true};
        boolean[] waited = {true, true};
        RenderConfigException primary = failure("copy failed");

        Throwable result = OpenXRStereoRenderer.releaseWaitedImages(
            acquired, waited, eye -> {}, primary);

        Assertions.assertSame(primary, result);
        Assertions.assertArrayEquals(new boolean[]{false, false}, acquired);
        Assertions.assertArrayEquals(new boolean[]{false, false}, waited);
        Assertions.assertEquals(0, primary.getSuppressed().length);
    }

    @Test
    void acquiredButUnwaitedImageIsTrackedAndNeverReleased() {
        boolean[] acquired = {false, true};
        boolean[] waited = {false, false};
        List<Integer> attempts = new ArrayList<>();

        Throwable result = OpenXRStereoRenderer.releaseWaitedImages(
            acquired, waited, attempts::add, null);

        Assertions.assertNull(result);
        Assertions.assertTrue(attempts.isEmpty());
        Assertions.assertArrayEquals(new boolean[]{false, true}, acquired);
        Assertions.assertArrayEquals(new boolean[]{false, false}, waited);
    }

    @Test
    void partialAcquireCleanupReleasesOnlyTheCompletedWait() {
        boolean[] acquired = {true, true};
        boolean[] waited = {true, false};
        List<Integer> attempts = new ArrayList<>();
        RenderConfigException waitFailure = failure("right wait failed");

        Throwable result = OpenXRStereoRenderer.releaseWaitedImages(
            acquired, waited, attempts::add, waitFailure);

        Assertions.assertSame(waitFailure, result);
        Assertions.assertEquals(List.of(0), attempts);
        Assertions.assertArrayEquals(new boolean[]{false, true}, acquired);
        Assertions.assertArrayEquals(new boolean[]{false, false}, waited);
    }

    private static RenderConfigException failure(String message) {
        return new RenderConfigException(
            Component.literal("OpenXR test"), Component.literal(message));
    }
}
