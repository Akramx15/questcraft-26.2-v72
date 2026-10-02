package org.questcraft.veq.client.wrist;

import org.joml.Matrix4f;
import org.joml.Quaternionf;
import org.joml.Vector3f;
import org.questcraft.veq.client.config.WristPoseProfile;

/** Host coverage for final-face acquisition, margins and visibility dwell. */
public final class VepSurfaceVisibilityPolicySelfTest {
    private static final Vector3f BACK = new Vector3f(0.0F, 0.0F, -1.0F);
    private static final Vector3f FORWARD = new Vector3f(0.0F, 0.0F, 1.0F);
    private static final Vector3f SURFACE_POSITION = new Vector3f();
    private static final float SCALE = 0.5F;
    private static final float ASPECT = 0.5625F;

    private VepSurfaceVisibilityPolicySelfTest() {
    }

    public static void main(String[] args) {
        VepSurfaceVisibilityPolicy policy = new VepSurfaceVisibilityPolicy();
        Matrix4f identity = new Matrix4f();
        Vector3f headFront = new Vector3f(0.0F, 0.0F, 1.0F);

        require(!update(policy, 0L, headFront, identity, BACK, null, null, FORWARD,
                        identity, false, false, 150L, 200L),
                "final-face aim must honor the open dwell");
        require(!update(policy, 149L, headFront, identity, BACK, null, null, FORWARD,
                        identity, false, false, 150L, 200L),
                "surface opened before 150 ms");
        require(update(policy, 150L, headFront, identity, BACK, null, null, FORWARD,
                        identity, false, false, 150L, 200L),
                "front-face head ray did not open the surface");

        Matrix4f lookAway = new Matrix4f().rotateY((float) Math.PI);
        require(update(policy, 151L, headFront, lookAway, BACK, null, null, FORWARD,
                        identity, false, false, 150L, 200L),
                "surface closed without the close dwell");
        require(update(policy, 350L, headFront, lookAway, BACK, null, null, FORWARD,
                        identity, false, false, 150L, 200L),
                "surface closed before 200 ms");
        require(!update(policy, 351L, headFront, lookAway, BACK, null, null, FORWARD,
                        identity, false, false, 150L, 200L),
                "surface did not close after 200 ms");

        policy.reset();
        require(update(policy, 0L, headFront, lookAway, BACK, null, null, FORWARD,
                        identity, true, false, 150L, 200L),
                "manual latch must open immediately");
        require(update(policy, 1L, headFront, lookAway, BACK, null, null, FORWARD,
                        identity, false, true, 150L, 200L),
                "hover/press/drag/carried retention must keep the surface open");

        policy.reset();
        Matrix4f pointerTowardSurface = new Matrix4f();
        require(update(policy, 0L, headFront, lookAway, BACK,
                        headFront, pointerTowardSurface, BACK,
                        identity, false, false, 0L, 200L),
                "opposite-hand AIM must acquire exact final bounds");
        policy.reset();
        require(!update(policy, 0L, headFront, lookAway, BACK,
                        headFront, pointerTowardSurface, FORWARD,
                        identity, false, false, 0L, 200L),
                "a backwards (+Z) controller ray must not acquire the surface");

        policy.reset();
        WristPoseProfile flippedProfile = new WristPoseProfile(
                0.0F, 0.0F, 0.0F,
                0.0F, 0.0F, 0.0F, 1.0F,
                true,
                SCALE
        );
        Matrix4f flippedSurface = new Matrix4f();
        WristOverlayPoseMath.composeAimPose(
                identity,
                SURFACE_POSITION,
                flippedProfile,
                new Vector3f(),
                flippedSurface,
                new Vector3f(),
                new Quaternionf()
        );
        require(!update(policy, 0L, headFront, identity, BACK, null, null, FORWARD,
                        flippedSurface, false, false, 0L, 200L),
                "Flip Face must reject the old front side");
        Vector3f headBehind = new Vector3f(0.0F, 0.0F, -1.0F);
        require(update(policy, 0L, headBehind, identity, FORWARD, null, null, FORWARD,
                        flippedSurface, false, false, 0L, 200L),
                "Flip Face must acquire from the new final front side");

        policy.reset();
        Vector3f marginHead = new Vector3f(0.40F, 0.0F, 1.0F);
        require(update(policy, 0L, marginHead, identity, BACK, null, null, FORWARD,
                        identity, false, false, 0L, 200L),
                "HMD acquisition must retain VEP's expanded horizontal margin");
        policy.reset();
        require(!update(policy, 0L, headFront, lookAway, BACK,
                        marginHead, pointerTowardSurface, BACK,
                        identity, false, false, 0L, 200L),
                "opposite-hand acquisition must remain inside exact content bounds");

        policy.reset();
        Matrix4f upsideDownSurface = new Matrix4f().rotateZ((float) Math.PI);
        require(!update(policy, 0L, headFront, identity, BACK, null, null, BACK,
                        upsideDownSurface, false, false, 0L, 200L),
                "HMD acquisition must reject an upside-down wrist surface");
        require(update(policy, 0L, headFront, lookAway, BACK,
                        headFront, pointerTowardSurface, BACK,
                        upsideDownSurface, false, false, 0L, 200L),
                "the opposite-hand pointer must still acquire an intentionally flipped surface");

        System.out.println("VepSurfaceVisibilityPolicySelfTest PASS");
    }

    private static boolean update(
            VepSurfaceVisibilityPolicy policy,
            long now,
            Vector3f headPosition,
            Matrix4f headRotation,
            Vector3f headForward,
            Vector3f pointerPosition,
            Matrix4f pointerRotation,
            Vector3f pointerForward,
            Matrix4f surfaceRotation,
            boolean manual,
            boolean retained,
            long openDelay,
            long closeDelay
    ) {
        return policy.update(
                now,
                headPosition,
                headRotation,
                headForward,
                pointerPosition,
                pointerRotation,
                pointerForward,
                SURFACE_POSITION,
                surfaceRotation,
                SCALE,
                ASPECT,
                0.25F,
                0.25F,
                0.75F,
                0.75F,
                manual,
                retained,
                openDelay,
                closeDelay
        );
    }

    private static void require(boolean condition, String message) {
        if (!condition) {
            throw new AssertionError(message);
        }
    }
}
