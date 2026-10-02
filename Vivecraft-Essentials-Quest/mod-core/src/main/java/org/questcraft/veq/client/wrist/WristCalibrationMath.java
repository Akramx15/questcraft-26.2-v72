package org.questcraft.veq.client.wrist;

import org.joml.Matrix4f;
import org.joml.Matrix4fc;
import org.joml.Quaternionf;
import org.joml.Vector3f;
import org.joml.Vector3fc;

/** Allocation-free conversion from a controller drag to an anchor-local pose. */
public final class WristCalibrationMath {
    private WristCalibrationMath() {
    }

    public static void controllerDeltaToAnchor(
            Matrix4fc startControllerRotation,
            Vector3fc startControllerPosition,
            Matrix4fc currentControllerRotation,
            Vector3fc currentControllerPosition,
            Matrix4fc startOverlayRotation,
            Vector3fc startOverlayPosition,
            Matrix4fc anchorRotation,
            Vector3fc anchorPosition,
            Vector3f localOffset,
            Quaternionf localRotation,
            Matrix4f startControllerInverse,
            Matrix4f deltaRotation,
            Matrix4f anchorInverse,
            Matrix4f roomRotation,
            Matrix4f localRotationMatrix,
            Vector3f offsetFromController,
            Vector3f roomPosition
    ) {
        startControllerRotation.invert(startControllerInverse);
        deltaRotation.set(currentControllerRotation).mul(startControllerInverse);
        startOverlayPosition.sub(startControllerPosition, offsetFromController);
        deltaRotation.transformDirection(offsetFromController, roomPosition);
        roomPosition.add(currentControllerPosition);
        roomRotation.set(deltaRotation).mul(startOverlayRotation);

        anchorRotation.invert(anchorInverse);
        roomPosition.sub(anchorPosition, localOffset);
        anchorInverse.transformDirection(localOffset);
        localRotationMatrix.set(anchorInverse).mul(roomRotation);
        localRotationMatrix.getNormalizedRotation(localRotation).normalize();
    }
}
