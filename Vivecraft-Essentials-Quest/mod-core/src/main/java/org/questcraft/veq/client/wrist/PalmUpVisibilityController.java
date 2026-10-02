package org.questcraft.veq.client.wrist;

/**
 * Allocation-free delayed hysteresis for the palm-up gesture.
 *
 * <p>The opening and closing timers are intentionally independent. A brief
 * tracking wobble around either threshold cannot flicker the inventory.</p>
 */
public final class PalmUpVisibilityController {
    private boolean visible;
    private long openCandidateSince = -1L;
    private long closeCandidateSince = -1L;

    public boolean update(
            float palmUpScore,
            long nowMillis,
            float openThreshold,
            float closeThreshold,
            long openDelayMillis,
            long closeDelayMillis
    ) {
        if (!Float.isFinite(palmUpScore)) {
            reset();
            return false;
        }

        if (!visible) {
            closeCandidateSince = -1L;
            if (palmUpScore >= openThreshold) {
                if (openCandidateSince < 0L) {
                    openCandidateSince = nowMillis;
                }
                if (nowMillis - openCandidateSince >= openDelayMillis) {
                    visible = true;
                    openCandidateSince = -1L;
                }
            } else {
                openCandidateSince = -1L;
            }
        } else {
            openCandidateSince = -1L;
            if (palmUpScore <= closeThreshold) {
                if (closeCandidateSince < 0L) {
                    closeCandidateSince = nowMillis;
                }
                if (nowMillis - closeCandidateSince >= closeDelayMillis) {
                    visible = false;
                    closeCandidateSince = -1L;
                }
            } else {
                closeCandidateSince = -1L;
            }
        }
        return visible;
    }

    public boolean isVisible() {
        return visible;
    }

    public void reset() {
        visible = false;
        openCandidateSince = -1L;
        closeCandidateSince = -1L;
    }
}
