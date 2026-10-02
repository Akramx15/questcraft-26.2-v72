package org.vivecraft.client_vr.provider.openxr;

import org.joml.Matrix4f;
import org.joml.Matrix4fc;

/** Pose helpers shared by the OpenXR provider and its Host tests. */
final class OpenXRPoseMath {
    private OpenXRPoseMath() {
    }

    /**
     * Computes the component-local transform that changes an OpenXR aim pose
     * into the corresponding full grip pose. Keeping translation here avoids
     * constructing a hybrid pose from the aim position and grip orientation.
     * All storage is supplied by the caller so the tracking loop does not allocate.
     */
    static void aimToGrip(
        Matrix4fc aimPose, Matrix4fc gripPose, Matrix4f inverseAimScratch, Matrix4f destination)
    {
        inverseAimScratch.set(aimPose).invert();
        destination.set(gripPose);
        inverseAimScratch.mul(destination, destination);
    }
}
