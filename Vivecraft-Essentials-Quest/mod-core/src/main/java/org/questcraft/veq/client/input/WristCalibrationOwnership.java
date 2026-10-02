package org.questcraft.veq.client.input;

import org.questcraft.veq.VivecraftEssentialsQuest;
import org.questcraft.veq.client.overlay.WristOverlayHandler;

import java.lang.reflect.Method;

/**
 * Narrow compatibility hook for the schema-3 wrist editor commit. This grip
 * commit can be built before that commit; once {@code isCalibrating()} is
 * present, it is discovered once and calibration owns both hands.
 */
final class WristCalibrationOwnership {
    private static boolean resolved;
    private static Method isCalibrating;
    private static boolean invocationFailureLogged;
    private static boolean observationStarted;
    private static boolean lastCalibrating;
    private static boolean currentCalibrating;

    private WristCalibrationOwnership() {
    }

    static boolean ownsHands() {
        pollEnded();
        return currentCalibrating;
    }

    /**
     * Polls the optional wrist branch API and reports its true-to-false edge.
     * The Grip gate uses that edge to consume the calibration press until a
     * real per-controller release is sampled.
     */
    static boolean pollEnded() {
        resolve();
        if (isCalibrating == null) {
            return false;
        }
        boolean calibrating;
        try {
            calibrating = (boolean) isCalibrating.invoke(null);
        } catch (ReflectiveOperationException | RuntimeException exception) {
            if (!invocationFailureLogged) {
                invocationFailureLogged = true;
                VivecraftEssentialsQuest.LOGGER.warn(
                        "Wrist calibration ownership hook failed; radial stays fail-closed",
                        exception);
            }
            calibrating = true;
        }
        boolean ended = observationStarted && lastCalibrating && !calibrating;
        observationStarted = true;
        lastCalibrating = calibrating;
        currentCalibrating = calibrating;
        return ended;
    }

    private static synchronized void resolve() {
        if (resolved) {
            return;
        }
        resolved = true;
        try {
            isCalibrating = WristOverlayHandler.class.getMethod("isCalibrating");
        } catch (NoSuchMethodException ignored) {
            // Expected when this commit is tested before the wrist commit.
        }
    }
}
