package org.questcraft.veq.client.wrist;

import org.joml.Matrix4f;
import org.joml.Matrix4fc;
import org.joml.Quaternionf;
import org.joml.Vector3f;
import org.joml.Vector3fc;
import org.questcraft.veq.client.config.WristPoseProfile;

/** Deterministic AIM-local pose composition with no HMD-dependent flip. */
public final class WristOverlayPoseMath {
    private WristOverlayPoseMath() {
    }

    public static void composeAimPose(
            Matrix4fc aimRotation,
            Vector3fc aimPosition,
            WristPoseProfile profile,
            Vector3f roomPosition,
            Matrix4f roomRotation,
            Vector3f offsetScratch,
            Quaternionf rotationScratch
    ) {
        profile.offset(offsetScratch);
        aimRotation.transformDirection(offsetScratch);
        aimPosition.add(offsetScratch, roomPosition);
        roomRotation.set(aimRotation).rotate(profile.rotation(rotationScratch));
    }
}
