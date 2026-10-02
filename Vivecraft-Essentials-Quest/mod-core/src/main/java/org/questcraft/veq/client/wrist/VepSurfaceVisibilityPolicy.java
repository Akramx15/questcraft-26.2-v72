package org.questcraft.veq.client.wrist;

import org.joml.Matrix4fc;
import org.joml.Vector2f;
import org.joml.Vector3f;
import org.joml.Vector3fc;

/**
 * VEP-style acquisition policy evaluated against the wrist surface's final,
 * calibrated room pose.
 *
 * <p>The old gesture compared a controller-local palm axis with the HMD. That
 * meant a pose edit or {@code Flip Face} changed what was rendered without
 * changing what opened the panel. This policy instead ray-tests the HMD and
 * the opposite controller against the same front face used for rendering and
 * pointer input.</p>
 */
public final class VepSurfaceVisibilityPolicy {
    /** Original VEP HMD acquisition expansion: 0.3 on each horizontal side. */
    public static final float HMD_EXTRA_BOUNDS_X = 0.60F;
    /** Original VEP HMD acquisition expansion: 0.5 on each vertical side. */
    public static final float HMD_EXTRA_BOUNDS_Y = 1.00F;
    /** VEP's original minimum front/up facing dot product. */
    static final float HMD_FACING_DOT = 0.20F;

    private final Vector3f headDirection = new Vector3f();
    private final Vector3f pointerDirection = new Vector3f();
    private final Vector2f uv = new Vector2f();
    private final Vector3f normal = new Vector3f();
    private final Vector3f right = new Vector3f();
    private final Vector3f up = new Vector3f();
    private final Vector3f topLeft = new Vector3f();
    private final Vector3f delta = new Vector3f();
    private final Vector3f intersection = new Vector3f();
    private final Vector3f surfaceUp = new Vector3f();

    private boolean visible;
    private long openCandidateSince = -1L;
    private long closeCandidateSince = -1L;

    /**
     * Evaluates one frame without allocating.
     *
     * @param headLocalForward local forward axis for the HMD (Vivecraft uses -Z)
     * @param pointerPosition null when the opposite controller is unavailable
     * @param pointerRotation null when the opposite controller is unavailable
     * @param pointerLocalForward local forward axis for the controller AIM pose
     */
    public boolean update(
            long nowMillis,
            Vector3fc headPosition,
            Matrix4fc headRotation,
            Vector3fc headLocalForward,
            Vector3fc pointerPosition,
            Matrix4fc pointerRotation,
            Vector3fc pointerLocalForward,
            Vector3fc surfacePosition,
            Matrix4fc surfaceRotation,
            float surfaceScale,
            float aspect,
            float minU,
            float minV,
            float maxU,
            float maxV,
            boolean manualLatch,
            boolean interactionRetained,
            long openDelayMillis,
            long closeDelayMillis
    ) {
        boolean headAimed = isHeadFacingUsableSurface(surfaceRotation)
                && rayHits(
                headPosition,
                headRotation,
                headLocalForward,
                surfacePosition,
                surfaceRotation,
                surfaceScale,
                aspect,
                minU - HMD_EXTRA_BOUNDS_X * 0.5F,
                minV - HMD_EXTRA_BOUNDS_Y * 0.5F,
                maxU + HMD_EXTRA_BOUNDS_X * 0.5F,
                maxV + HMD_EXTRA_BOUNDS_Y * 0.5F,
                this.headDirection,
                true
        );
        boolean pointerAimed = pointerPosition != null && pointerRotation != null && rayHits(
                pointerPosition,
                pointerRotation,
                pointerLocalForward,
                surfacePosition,
                surfaceRotation,
                surfaceScale,
                aspect,
                minU,
                minV,
                maxU,
                maxV,
                this.pointerDirection,
                false
        );
        return updateState(
                nowMillis,
                manualLatch,
                interactionRetained,
                headAimed || pointerAimed,
                openDelayMillis,
                closeDelayMillis
        );
    }

    /** Package-private deterministic state seam used by Host tests. */
    boolean updateState(
            long nowMillis,
            boolean manualLatch,
            boolean interactionRetained,
            boolean aimedAtFinalFace,
            long openDelayMillis,
            long closeDelayMillis
    ) {
        if (manualLatch) {
            this.visible = true;
            this.openCandidateSince = -1L;
            this.closeCandidateSince = -1L;
            return true;
        }

        long safeOpenDelay = Math.max(0L, openDelayMillis);
        long safeCloseDelay = Math.max(0L, closeDelayMillis);
        if (!this.visible) {
            this.closeCandidateSince = -1L;
            if (!aimedAtFinalFace) {
                this.openCandidateSince = -1L;
                return false;
            }
            if (this.openCandidateSince < 0L) {
                this.openCandidateSince = nowMillis;
            }
            if (elapsed(nowMillis, this.openCandidateSince) >= safeOpenDelay) {
                this.visible = true;
                this.openCandidateSince = -1L;
            }
            return this.visible;
        }

        this.openCandidateSince = -1L;
        if (aimedAtFinalFace || interactionRetained) {
            this.closeCandidateSince = -1L;
            return true;
        }
        if (this.closeCandidateSince < 0L) {
            this.closeCandidateSince = nowMillis;
        }
        if (elapsed(nowMillis, this.closeCandidateSince) >= safeCloseDelay) {
            this.visible = false;
            this.closeCandidateSince = -1L;
        }
        return this.visible;
    }

    public boolean isVisible() {
        return this.visible;
    }

    public void reset() {
        this.visible = false;
        this.openCandidateSince = -1L;
        this.closeCandidateSince = -1L;
    }

    private boolean rayHits(
            Vector3fc rayPosition,
            Matrix4fc rayRotation,
            Vector3fc localForward,
            Vector3fc surfacePosition,
            Matrix4fc surfaceRotation,
            float surfaceScale,
            float aspect,
            float minU,
            float minV,
            float maxU,
            float maxV,
            Vector3f directionScratch,
            boolean requireFrontFacingThreshold
    ) {
        if (rayPosition == null || rayRotation == null || localForward == null
                || surfacePosition == null || surfaceRotation == null) {
            return false;
        }
        rayRotation.transformDirection(localForward, directionScratch);
        float lengthSquared = directionScratch.lengthSquared();
        if (!Float.isFinite(lengthSquared) || lengthSquared < 1.0E-8F) {
            return false;
        }
        directionScratch.mul((float) (1.0 / Math.sqrt(lengthSquared)));
        if (requireFrontFacingThreshold) {
            surfaceRotation.transformDirection(0.0F, 0.0F, 1.0F, this.normal);
            float normalLengthSquared = this.normal.lengthSquared();
            if (!Float.isFinite(normalLengthSquared) || normalLengthSquared < 1.0E-8F) {
                return false;
            }
            this.normal.mul((float) (1.0 / Math.sqrt(normalLengthSquared)));
            if (-this.normal.dot(directionScratch) <= HMD_FACING_DOT) {
                return false;
            }
        }
        return WristSurfaceMath.rayToUv(
                rayPosition,
                directionScratch,
                surfacePosition,
                surfaceRotation,
                surfaceScale,
                aspect,
                this.uv,
                this.normal,
                this.right,
                this.up,
                this.topLeft,
                this.delta,
                this.intersection
        ) && WristSurfaceMath.isWithin(this.uv, minU, minV, maxU, maxV);
    }

    /** Mirrors VEP's checkUpsideDown=true rule for HMD acquisition only. */
    private boolean isHeadFacingUsableSurface(Matrix4fc surfaceRotation) {
        if (surfaceRotation == null) {
            return false;
        }
        surfaceRotation.transformDirection(0.0F, 1.0F, 0.0F, this.surfaceUp);
        float lengthSquared = this.surfaceUp.lengthSquared();
        if (!Float.isFinite(lengthSquared) || lengthSquared < 1.0E-8F) {
            return false;
        }
        this.surfaceUp.mul((float) (1.0 / Math.sqrt(lengthSquared)));
        return this.surfaceUp.y > HMD_FACING_DOT;
    }

    private static long elapsed(long nowMillis, long sinceMillis) {
        if (nowMillis < sinceMillis) {
            return 0L;
        }
        return nowMillis - sinceMillis;
    }
}
