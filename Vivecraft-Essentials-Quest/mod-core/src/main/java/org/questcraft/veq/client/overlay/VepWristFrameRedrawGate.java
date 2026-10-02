package org.questcraft.veq.client.overlay;

/**
 * Allocation-free redraw policy for the retained wrist content target.
 *
 * <p>The presentation target and its pointer/carried pass remain frame-rate
 * synchronous. Only the expensive base Screen extraction is throttled. A
 * bounded refresh keeps item glint, status effects, tooltips and other Vanilla
 * animations advancing without rebuilding the entire 1008x540 target at the
 * headset refresh rate.</p>
 *
 * <p>{@link #shouldRedraw} is deliberately side-effect free. The caller must
 * invoke {@link #markRendered} only after Screen extraction completes, so a
 * failed draw is retried on the next frame instead of being treated as clean.</p>
 */
final class VepWristFrameRedrawGate {
    static final long IDLE_REFRESH_NANOS = 50_000_000L;

    private boolean snapshotValid;
    private Object screen;
    private int hoverKey;
    private long renderedAtNanos;

    boolean shouldRedraw(
            long nowNanos,
            Object activeScreen,
            int nextHoverKey,
            boolean animatedPreview
    ) {
        return !this.snapshotValid
                || this.screen != activeScreen
                || this.hoverKey != nextHoverKey
                || animatedPreview
                || nowNanos < this.renderedAtNanos
                || nowNanos - this.renderedAtNanos >= IDLE_REFRESH_NANOS;
    }

    void markRendered(long nowNanos, Object activeScreen, int nextHoverKey) {
        this.snapshotValid = true;
        this.screen = activeScreen;
        this.hoverKey = nextHoverKey;
        this.renderedAtNanos = nowNanos;
    }

    void invalidate() {
        this.snapshotValid = false;
        this.screen = null;
    }
}
