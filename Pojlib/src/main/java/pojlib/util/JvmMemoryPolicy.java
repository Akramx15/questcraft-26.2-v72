package pojlib.util;

/**
 * Resolves the bounded Java heap used by the personal Quest build.
 *
 * <p>This class deliberately has no Android dependencies so the policy can be
 * exercised by local unit tests. The caller supplies the memory remaining
 * after Android's low-memory threshold has been reserved.</p>
 */
public final class JvmMemoryPolicy {
    public static final int INITIAL_HEAP_MIB = 512;
    public static final int MIN_MAX_HEAP_MIB = 1536;
    public static final int AUTO_TARGET_HEAP_MIB = 1536;
    public static final int AUTO_NATIVE_HEADROOM_MIB = 1024;
    public static final int MAX_MAX_HEAP_MIB = 2048;

    private JvmMemoryPolicy() {}

    public enum Source {
        AUTO("auto"),
        CUSTOM("custom"),
        AUTO_AFTER_INVALID_CUSTOM("auto-invalid-custom");

        private final String logName;

        Source(String logName) {
            this.logName = logName;
        }

        public String getLogName() {
            return logName;
        }
    }

    public static final class Decision {
        private final int initialHeapMiB;
        private final int maximumHeapMiB;
        private final Source source;

        private Decision(int initialHeapMiB, int maximumHeapMiB, Source source) {
            this.initialHeapMiB = initialHeapMiB;
            this.maximumHeapMiB = maximumHeapMiB;
            this.source = source;
        }

        public int getInitialHeapMiB() {
            return initialHeapMiB;
        }

        public int getMaximumHeapMiB() {
            return maximumHeapMiB;
        }

        public Source getSource() {
            return source;
        }
    }

    /**
     * Resolves a safe heap decision. Invalid custom input falls back to the
     * automatic value without echoing the invalid input to logs.
     */
    public static Decision resolve(
            boolean customEnabled,
            String customMaximumMiB,
            long availableAfterThresholdMiB) {
        if (customEnabled) {
            Long requestedMiB = parseWholeMiB(customMaximumMiB);
            if (requestedMiB != null) {
                return decision(requestedMiB, Source.CUSTOM);
            }
            return automaticDecision(
                    availableAfterThresholdMiB,
                    Source.AUTO_AFTER_INVALID_CUSTOM);
        }
        return automaticDecision(availableAfterThresholdMiB, Source.AUTO);
    }

    private static Decision automaticDecision(long availableAfterThresholdMiB, Source source) {
        // ActivityManager's threshold only reserves Android's LMK threshold; it
        // does not account for Unity, Vulkan/OpenXR, the compositor, or native
        // LWJGL allocations. Keep an additional 1 GiB outside the Java heap and
        // use the conservative 1.5 GiB automatic target selected after the
        // first RC3 soak crossed the process-memory guardrail. Manual choices
        // remain separately bounded by the 2 GiB hard maximum.
        long headroomBound = saturatingSubtract(
                availableAfterThresholdMiB,
                AUTO_NATIVE_HEADROOM_MIB);
        return decision(Math.min(AUTO_TARGET_HEAP_MIB, headroomBound), source);
    }

    private static Decision decision(long requestedMaximumMiB, Source source) {
        int maximumHeapMiB = (int) Math.max(
                MIN_MAX_HEAP_MIB,
                Math.min(MAX_MAX_HEAP_MIB, requestedMaximumMiB));
        return new Decision(INITIAL_HEAP_MIB, maximumHeapMiB, source);
    }

    private static long saturatingSubtract(long value, long amount) {
        if (value <= amount) {
            return 0L;
        }
        return value - amount;
    }

    private static Long parseWholeMiB(String value) {
        if (value == null) {
            return null;
        }
        String normalized = value.trim();
        if (normalized.isEmpty()) {
            return null;
        }
        try {
            return Long.parseLong(normalized);
        } catch (NumberFormatException ignored) {
            return null;
        }
    }
}
