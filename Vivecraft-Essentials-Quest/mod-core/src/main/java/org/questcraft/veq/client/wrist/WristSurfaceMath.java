package org.questcraft.veq.client.wrist;

import org.joml.Matrix4fc;
import org.joml.Vector2f;
import org.joml.Vector3f;
import org.joml.Vector3fc;

/** Allocation-free controller-ray intersection for Vivecraft screen quads. */
public final class WristSurfaceMath {
    private static final float GUI_WORLD_SCALE = 1.5F;
    private static final float PARALLEL_EPSILON = 1.0E-5F;

    private WristSurfaceMath() {
    }

    public static boolean rayToUv(
            Vector3fc rayOrigin,
            Vector3fc rayDirection,
            Vector3fc overlayPosition,
            Matrix4fc overlayRotation,
            float overlayScale,
            float aspect,
            Vector2f uv,
            Vector3f normal,
            Vector3f right,
            Vector3f up,
            Vector3f topLeft,
            Vector3f delta,
            Vector3f intersection
    ) {
        if (!Float.isFinite(overlayScale) || overlayScale <= 0.0F ||
                !Float.isFinite(aspect) || aspect <= 0.0F) {
            return false;
        }

        overlayRotation.transformDirection(0.0F, 0.0F, 1.0F, normal).normalize();
        // RenderHelper's screen quad maps texture U=0 to local -X and U=1 to
        // local +X. Keep pointer space on that exact basis; using -X here
        // mirrored every click relative to the image the player saw.
        overlayRotation.transformDirection(1.0F, 0.0F, 0.0F, right).normalize();
        overlayRotation.transformDirection(0.0F, 1.0F, 0.0F, up).normalize();

        float denominator = normal.dot(rayDirection);
        // The quad's visible/front face has local normal +Z. Only accept a
        // ray travelling toward that face. A two-sided plane intersection
        // lets a controller behind the wrist click the mirrored back face.
        if (!Float.isFinite(denominator) || denominator >= -PARALLEL_EPSILON) {
            return false;
        }

        topLeft.set(overlayPosition)
                .sub(up.mul(0.5F, delta))
                .sub(right.mul(0.5F, intersection));
        rayOrigin.sub(topLeft, delta);
        float distance = -normal.dot(delta) / denominator;
        if (!Float.isFinite(distance) || distance <= 0.0F) {
            return false;
        }

        rayDirection.mul(distance, intersection)
                .add(rayOrigin)
                .sub(topLeft);
        float u = intersection.dot(right);
        float v = intersection.dot(up);
        u = (u - 0.5F) / GUI_WORLD_SCALE / overlayScale + 0.5F;
        v = 1.0F - ((v - 0.5F) / aspect / GUI_WORLD_SCALE / overlayScale + 0.5F);
        if (!Float.isFinite(u) || !Float.isFinite(v)) {
            return false;
        }
        uv.set(u, v);
        return true;
    }

    public static boolean isWithin(Vector2f uv, float minU, float minV, float maxU, float maxV) {
        return uv.x >= minU && uv.x <= maxU && uv.y >= minV && uv.y <= maxV;
    }
}
