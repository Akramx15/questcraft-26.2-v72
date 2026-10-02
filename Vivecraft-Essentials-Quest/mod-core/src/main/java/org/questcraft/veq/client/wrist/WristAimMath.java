package org.questcraft.veq.client.wrist;

import org.joml.Matrix4fc;
import org.joml.Vector3f;
import org.joml.Vector3fc;
import org.questcraft.veq.client.config.PalmAxis;

/** Allocation-free math for the VEP-style palm-to-HMD acquisition gesture. */
public final class WristAimMath {
    private static final float STRICT_OPEN_THRESHOLD = 0.75F;
    private static final float EASY_OPEN_THRESHOLD = 0.05F;
    private static final float HYSTERESIS_WIDTH = 0.12F;

    private WristAimMath() {
    }

    public static float openThreshold(float sensitivity) {
        float normalized = clamp01(sensitivity);
        return STRICT_OPEN_THRESHOLD + (EASY_OPEN_THRESHOLD - STRICT_OPEN_THRESHOLD) * normalized;
    }

    public static float closeThreshold(float sensitivity) {
        return Math.max(-1.0F, openThreshold(sensitivity) - HYSTERESIS_WIDTH);
    }

    public static float facingScore(
            PalmAxis palmAxis,
            Matrix4fc handRotation,
            Vector3fc handPosition,
            Vector3fc hmdPosition,
            Vector3f palmScratch,
            Vector3f toHmdScratch
    ) {
        palmAxis.transformDirection(handRotation, palmScratch).normalize();
        hmdPosition.sub(handPosition, toHmdScratch);
        float lengthSquared = toHmdScratch.lengthSquared();
        if (!Float.isFinite(lengthSquared) || lengthSquared < 1.0E-8F) {
            return -1.0F;
        }
        toHmdScratch.mul((float) (1.0 / Math.sqrt(lengthSquared)));
        float score = palmScratch.dot(toHmdScratch);
        return Float.isFinite(score) ? score : -1.0F;
    }

    private static float clamp01(float value) {
        if (!Float.isFinite(value)) {
            return 0.5F;
        }
        return Math.max(0.0F, Math.min(1.0F, value));
    }
}
