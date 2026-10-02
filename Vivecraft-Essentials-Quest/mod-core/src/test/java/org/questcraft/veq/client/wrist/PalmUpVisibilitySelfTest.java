package org.questcraft.veq.client.wrist;

import org.joml.Matrix4f;
import org.joml.Quaternionf;
import org.joml.Vector3f;
import org.questcraft.veq.client.config.PalmAxis;
import org.questcraft.veq.client.config.WristPoseProfile;

public final class PalmUpVisibilitySelfTest {
    private PalmUpVisibilitySelfTest() {
    }

    public static void main(String[] args) {
        PalmUpVisibilityController state = new PalmUpVisibilityController();
        require(!state.update(0.30F, 0L, 0.20F, 0.10F, 150L, 150L), "opens too early");
        require(!state.update(0.30F, 149L, 0.20F, 0.10F, 150L, 150L), "opens before delay");
        require(state.update(0.30F, 150L, 0.20F, 0.10F, 150L, 150L), "did not open");
        require(state.update(0.15F, 250L, 0.20F, 0.10F, 150L, 150L), "hysteresis flicker");
        require(state.update(0.05F, 300L, 0.20F, 0.10F, 150L, 150L), "closes too early");
        require(!state.update(0.05F, 450L, 0.20F, 0.10F, 150L, 150L), "did not close");
        require(!state.update(Float.NaN, 500L, 0.20F, 0.10F, 150L, 150L), "invalid score remains visible");

        Vector3f palmScratch = new Vector3f();
        Vector3f toHmdScratch = new Vector3f();
        Matrix4f identity = new Matrix4f();
        requireNear(
                WristAimMath.facingScore(
                        PalmAxis.POSITIVE_Y,
                        identity,
                        new Vector3f(),
                        new Vector3f(0.0F, 1.0F, 0.0F),
                        palmScratch,
                        toHmdScratch
                ),
                1.0F,
                "palm facing HMD"
        );
        requireNear(
                WristAimMath.facingScore(
                        PalmAxis.POSITIVE_Y,
                        identity,
                        new Vector3f(),
                        new Vector3f(0.0F, -1.0F, 0.0F),
                        palmScratch,
                        toHmdScratch
                ),
                -1.0F,
                "palm facing away"
        );
        requireNear(WristAimMath.openThreshold(0.0F), 0.75F, "strict sensitivity threshold");
        requireNear(WristAimMath.openThreshold(1.0F), 0.05F, "easy sensitivity threshold");
        requireNear(WristAimMath.openThreshold(0.55F), 0.365F, "default sensitivity threshold");
        requireNear(WristAimMath.closeThreshold(0.55F), 0.245F, "default hysteresis threshold");

        Quaternionf expectedRotation = new Quaternionf().rotationZYX(0.3F, -0.2F, 0.1F);
        WristPoseProfile profile = WristPoseProfile.of(
                new Vector3f(0.1F, 0.2F, 0.3F),
                expectedRotation,
                0.5F
        );
        Vector3f roomPosition = new Vector3f();
        Matrix4f roomRotation = new Matrix4f();
        WristOverlayPoseMath.composeAimPose(
                identity,
                new Vector3f(1.0F, 2.0F, 3.0F),
                profile,
                roomPosition,
                roomRotation,
                new Vector3f(),
                new Quaternionf()
        );
        requireNear(roomPosition.x, 1.1F, "AIM-local x offset");
        requireNear(roomPosition.y, 2.2F, "AIM-local y offset");
        requireNear(roomPosition.z, 3.3F, "AIM-local z offset");
        Quaternionf actualRotation = roomRotation.getNormalizedRotation(new Quaternionf());
        require(Math.abs(actualRotation.dot(expectedRotation)) > 0.99999F,
                "Rz * Ry * Rx quaternion must be preserved without an HMD flip");

        Vector3f calibratedOffset = new Vector3f();
        Quaternionf calibratedRotation = new Quaternionf();
        WristCalibrationMath.controllerDeltaToAnchor(
                identity,
                new Vector3f(),
                identity,
                new Vector3f(1.0F, 2.0F, 3.0F),
                identity,
                new Vector3f(0.2F, 0.3F, 0.4F),
                identity,
                new Vector3f(1.0F, 1.0F, 1.0F),
                calibratedOffset,
                calibratedRotation,
                new Matrix4f(),
                new Matrix4f(),
                new Matrix4f(),
                new Matrix4f(),
                new Matrix4f(),
                new Vector3f(),
                new Vector3f()
        );
        requireNear(calibratedOffset.x, 0.2F, "calibration x translation");
        requireNear(calibratedOffset.y, 1.3F, "calibration y translation");
        requireNear(calibratedOffset.z, 2.4F, "calibration z translation");
        require(Math.abs(calibratedRotation.w) > 0.99999F,
                "identity controller drag must retain identity rotation");
    }

    private static void require(boolean condition, String message) {
        if (!condition) {
            throw new AssertionError(message);
        }
    }

    private static void requireNear(float actual, float expected, String message) {
        if (Math.abs(actual - expected) > 1.0E-5F) {
            throw new AssertionError(message + ": expected " + expected + " but was " + actual);
        }
    }
}
