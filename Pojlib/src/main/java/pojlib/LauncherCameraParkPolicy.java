package pojlib;

import java.util.Locale;

/**
 * Pure-Java policy for launcher camera parking.
 *
 * <p>The isolated Lab package and the accepted Personal package opt in for
 * ordinary manual launches. Only the Lab package can consume an unattended
 * request and temporarily override that default with an explicit {@code ON}
 * or {@code OFF} value. Keeping package eligibility and state independent of
 * Android makes the security-sensitive normalization and lifecycle directly
 * unit-testable.</p>
 */
final class LauncherCameraParkPolicy {
    private static final String LAB_PACKAGE = "com.qcxr.qcxr.canary262";
    private static final String PERSONAL_PACKAGE = "com.qcxr.qcxr.dev262";

    static final String MODE_ON = "ON";
    static final String MODE_OFF = "OFF";

    static final String STATUS_APPLIED = "APPLIED";
    static final String STATUS_NO_CAMERAS = "NO_CAMERAS";
    static final String STATUS_FAILED = "FAILED";

    static final String MANUAL_RUN_ID = "manual";

    private LauncherCameraParkPolicy() {
    }

    static boolean isEligiblePackage(String packageName) {
        return LAB_PACKAGE.equals(packageName) || PERSONAL_PACKAGE.equals(packageName);
    }

    static String normalizeMode(String mode) {
        if(mode == null) {
            return null;
        }
        String normalized = mode.trim().toUpperCase(Locale.ROOT);
        if(MODE_ON.equals(normalized) || MODE_OFF.equals(normalized)) {
            return normalized;
        }
        return null;
    }

    static String normalizeStatus(String status) {
        if(status == null) {
            return null;
        }
        String normalized = status.trim().toUpperCase(Locale.ROOT);
        if(STATUS_APPLIED.equals(normalized)
                || STATUS_NO_CAMERAS.equals(normalized)
                || STATUS_FAILED.equals(normalized)) {
            return normalized;
        }
        return null;
    }

    static final class State {
        private String activeRunId;
        private String activeMode;

        void activate(String runId, String mode) {
            String normalizedMode = normalizeMode(mode);
            if(runId == null || runId.isEmpty() || normalizedMode == null) {
                throw new IllegalArgumentException("A consumed run requires an id and ON/OFF mode.");
            }
            activeRunId = runId;
            activeMode = normalizedMode;
        }

        void abort() {
            clearOverride();
        }

        void complete() {
            clearOverride();
        }

        private void clearOverride() {
            activeRunId = null;
            activeMode = null;
        }

        boolean hasActiveOverride() {
            return activeRunId != null && activeMode != null;
        }

        boolean isEnabled(boolean eligiblePackage) {
            if(!eligiblePackage) {
                return false;
            }
            return activeMode == null || MODE_ON.equals(activeMode);
        }

        String getRunIdForLog() {
            return activeRunId == null ? MANUAL_RUN_ID : activeRunId;
        }

        String getModeForLog() {
            return activeMode == null ? MODE_ON : activeMode;
        }

        Result createResult(String status, int cameraCount) {
            if(!isEnabled(true)) {
                return null;
            }
            String normalizedStatus = normalizeStatus(status);
            if(normalizedStatus == null) {
                return null;
            }

            int normalizedCount = Math.max(0, cameraCount);
            if(STATUS_APPLIED.equals(normalizedStatus) && normalizedCount == 0) {
                return null;
            }
            if(STATUS_NO_CAMERAS.equals(normalizedStatus) && normalizedCount != 0) {
                return null;
            }
            return new Result(
                    getRunIdForLog(), getModeForLog(), normalizedStatus, normalizedCount);
        }
    }

    static final class Result {
        final String runId;
        final String mode;
        final String status;
        final int cameraCount;

        Result(String runId, String mode, String status, int cameraCount) {
            this.runId = runId;
            this.mode = mode;
            this.status = status;
            this.cameraCount = cameraCount;
        }
    }
}
