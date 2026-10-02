package org.questcraft.veq.client.radial;

import net.minecraft.util.Mth;
import org.joml.Matrix4f;
import org.joml.Vector3f;
import org.joml.Vector3fc;

/** Allocation-free orientation math for a frozen Grip selector surface. */
final class GripSurfacePoseMath {
    private GripSurfacePoseMath() {
    }

    /**
     * Points local +Z from the panel toward the viewer, matching Vivecraft's
     * ordinary GUI plane and the front-face convention used by pointer math.
     */
    static boolean orientTowardViewer(
            Vector3fc panelPosition,
            Vector3fc viewerPosition,
            Vector3f panelFromViewer,
            Matrix4f rotation
    ) {
        panelPosition.sub(viewerPosition, panelFromViewer);
        float length = panelFromViewer.length();
        if (!Float.isFinite(length) || length <= 1.0E-5F) {
            return false;
        }
        float pitch = (float) Math.asin(Mth.clamp(panelFromViewer.y / length, -1.0F, 1.0F));
        float yaw = Mth.PI + (float) Math.atan2(panelFromViewer.x, panelFromViewer.z);
        rotation.identity().rotationY(yaw).rotateX(pitch);
        return true;
    }
}
