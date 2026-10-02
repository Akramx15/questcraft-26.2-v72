package org.questcraft.veq.client.config;

import org.joml.Quaternionf;
import org.joml.Quaternionfc;
import org.joml.Vector3f;

/** Immutable, logical-controller-local pose used by the wrist surface. */
public record WristPoseProfile(
        float offsetX,
        float offsetY,
        float offsetZ,
        float rotationX,
        float rotationY,
        float rotationZ,
        float rotationW,
        boolean frontFaceFlipped,
        float scale
) {
    public Vector3f offset(Vector3f destination) {
        return destination.set(offsetX, offsetY, offsetZ);
    }

    public Quaternionf rotation(Quaternionf destination) {
        destination.set(rotationX, rotationY, rotationZ, rotationW).normalize();
        if (frontFaceFlipped) {
            destination.rotateY((float) Math.PI);
        }
        return destination;
    }

    /** Stored calibration quaternion before the independent face choice. */
    public Quaternionf baseRotation(Quaternionf destination) {
        return destination.set(rotationX, rotationY, rotationZ, rotationW).normalize();
    }

    public static WristPoseProfile of(Vector3f offset, Quaternionfc rotation, float scale) {
        return new WristPoseProfile(
                offset.x, offset.y, offset.z,
                rotation.x(), rotation.y(), rotation.z(), rotation.w(), false, scale
        );
    }
}
