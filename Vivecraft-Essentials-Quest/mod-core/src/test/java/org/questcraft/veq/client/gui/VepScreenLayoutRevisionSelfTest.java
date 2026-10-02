package org.questcraft.veq.client.gui;

public final class VepScreenLayoutRevisionSelfTest {
    private VepScreenLayoutRevisionSelfTest() {
    }

    public static void main(String[] args) {
        VepScreenLayoutRevision tracker = new VepScreenLayoutRevision();
        long revision = update(tracker, 100, 50, 504, 270, 7L, 2, 4L, 6);
        require(revision > 0L, "first layout state did not initialize");
        require(update(tracker, 100, 50, 504, 270, 7L, 2, 4L, 6) == revision,
                "unchanged layout advanced revision");

        revision = requireAdvance(tracker, revision,
                101, 50, 504, 270, 7L, 2, 4L, 6, "left position");
        revision = requireAdvance(tracker, revision,
                101, 51, 504, 270, 7L, 2, 4L, 6, "top position");
        revision = requireAdvance(tracker, revision,
                101, 51, 505, 270, 7L, 2, 4L, 6, "screen width");
        revision = requireAdvance(tracker, revision,
                101, 51, 505, 271, 7L, 2, 4L, 6, "screen height");
        revision = requireAdvance(tracker, revision,
                101, 51, 505, 271, 8L, 2, 4L, 6, "feature config");
        revision = requireAdvance(tracker, revision,
                101, 51, 505, 271, 8L, 3, 4L, 6, "visible effects");
        revision = requireAdvance(tracker, revision,
                101, 51, 505, 271, 8L, 3, 5L, 6, "utility registry");
        requireAdvance(tracker, revision,
                101, 51, 505, 271, 8L, 3, 5L, 12, "layout flags");
    }

    private static long requireAdvance(VepScreenLayoutRevision tracker,
                                       long previous,
                                       int left,
                                       int top,
                                       int width,
                                       int height,
                                       long featureRevision,
                                       int effectCount,
                                       long utilityRevision,
                                       int flags,
                                       String reason) {
        long next = update(tracker, left, top, width, height,
                featureRevision, effectCount, utilityRevision, flags);
        require(next == previous + 1L, reason + " did not advance revision exactly once");
        return next;
    }

    private static long update(VepScreenLayoutRevision tracker,
                               int left,
                               int top,
                               int width,
                               int height,
                               long featureRevision,
                               int effectCount,
                               long utilityRevision,
                               int flags) {
        return tracker.update(left, top, width, height, featureRevision,
                effectCount, utilityRevision, flags);
    }

    private static void require(boolean condition, String message) {
        if (!condition) {
            throw new AssertionError(message);
        }
    }
}
