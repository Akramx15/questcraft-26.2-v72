package pojlib;

import java.util.Locale;

/**
 * Process-local policy for launcher resource release after the OpenXR handoff.
 *
 * <p>The release is pinned to the prepared v71 identities and the exact v72
 * Stable identity. Manual launches release by default. An authenticated Lab
 * A/B run may request {@code OFF}; Stable rejects overrides.</p>
 */
final class LauncherResourceReleasePolicy {
    private static final String LAB_PACKAGE = "com.qcxr.qcxr.canary262";
    private static final long LAB_VERSION_CODE = 71L;
    private static final String LAB_RC4_VERSION_NAME =
            "6.0.1-26.2-vivecraft-personal.12-rc.4";
    private static final String LAB_RC5_VERSION_NAME =
            "6.0.1-26.2-vivecraft-personal.12-rc.5";
    private static final String LAB_RC5_1_VERSION_NAME =
            "6.0.1-26.2-vivecraft-personal.12-rc.5.1";
    private static final String LAB_RC5_2_VERSION_NAME =
            "6.0.1-26.2-vivecraft-personal.12-rc.5.2";
    private static final String LAB_RC6_VERSION_NAME =
            "6.0.1-26.2-vivecraft-personal.12-rc.6";
    private static final String LAB_RC6_1_VERSION_NAME =
            "6.0.1-26.2-vivecraft-personal.12-rc.6.1";
    private static final String LAB_RC6_2_VERSION_NAME =
            "6.0.1-26.2-vivecraft-personal.12-rc.6.2";
    private static final String LAB_RC7_VERSION_NAME =
            "6.0.1-26.2-vivecraft-personal.12-rc.7";
    private static final String LAB_RC8_VERSION_NAME =
            "6.0.1-26.2-vivecraft-personal.12-rc.8";
    private static final String STABLE_PACKAGE = "com.qcxr.qcxr.dev262";
    private static final long STABLE_VERSION_CODE = 71L;
    private static final String STABLE_VERSION_NAME =
            "6.0.1-26.2-vivecraft-personal.12";
    private static final long STABLE_V72_VERSION_CODE = 72L;
    private static final String STABLE_V72_VERSION_NAME =
            "6.0.1-26.2-vivecraft-personal.13";

    static final String MODE_ON = "ON";
    static final String MODE_OFF = "OFF";

    private LauncherResourceReleasePolicy() {
    }

    enum BuildIdentity {
        INELIGIBLE,
        LAB_V71_RC4,
        LAB_V71_RC5,
        STABLE_V71,
        STABLE_V72
    }

    static BuildIdentity resolveIdentity(
            String packageName, long versionCode, String versionName) {
        if(LAB_PACKAGE.equals(packageName) && versionCode == LAB_VERSION_CODE &&
                LAB_RC4_VERSION_NAME.equals(versionName)) {
            return BuildIdentity.LAB_V71_RC4;
        }
        if(LAB_PACKAGE.equals(packageName) && versionCode == LAB_VERSION_CODE &&
                (LAB_RC5_VERSION_NAME.equals(versionName) ||
                 LAB_RC5_1_VERSION_NAME.equals(versionName) ||
                 LAB_RC5_2_VERSION_NAME.equals(versionName) ||
                 LAB_RC6_VERSION_NAME.equals(versionName) ||
                 LAB_RC6_1_VERSION_NAME.equals(versionName) ||
                 LAB_RC6_2_VERSION_NAME.equals(versionName) ||
                 LAB_RC7_VERSION_NAME.equals(versionName) ||
                 LAB_RC8_VERSION_NAME.equals(versionName))) {
            return BuildIdentity.LAB_V71_RC5;
        }
        if(STABLE_PACKAGE.equals(packageName) && versionCode == STABLE_VERSION_CODE &&
                STABLE_VERSION_NAME.equals(versionName)) {
            return BuildIdentity.STABLE_V71;
        }
        if(STABLE_PACKAGE.equals(packageName) && versionCode == STABLE_V72_VERSION_CODE &&
                STABLE_V72_VERSION_NAME.equals(versionName)) {
            return BuildIdentity.STABLE_V72;
        }
        return BuildIdentity.INELIGIBLE;
    }

    static String normalizeOptionalMode(String mode) {
        if(mode == null || mode.trim().isEmpty()) {
            return MODE_OFF;
        }
        String normalized = mode.trim().toUpperCase(Locale.ROOT);
        if(MODE_ON.equals(normalized) || MODE_OFF.equals(normalized)) {
            return normalized;
        }
        return null;
    }

    static final class State {
        private String activeRunId;
        private String activeMode;

        void activate(String runId, String mode) {
            String normalizedMode = normalizeOptionalMode(mode);
            if(runId == null || runId.isEmpty() || normalizedMode == null) {
                throw new IllegalArgumentException("A consumed run requires an id and ON/OFF mode.");
            }
            activeRunId = runId;
            activeMode = normalizedMode;
        }

        void clear() {
            activeRunId = null;
            activeMode = null;
        }

        boolean hasActiveOverride() {
            return activeRunId != null && activeMode != null;
        }

        boolean shouldRelease(BuildIdentity identity) {
            if(identity == null || identity == BuildIdentity.INELIGIBLE) {
                return false;
            }
            if((identity == BuildIdentity.LAB_V71_RC4 ||
                    identity == BuildIdentity.LAB_V71_RC5) && hasActiveOverride()) {
                return MODE_ON.equals(activeMode);
            }
            return true;
        }
    }
}
