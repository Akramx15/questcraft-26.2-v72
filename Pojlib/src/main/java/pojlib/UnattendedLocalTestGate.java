package pojlib;

import android.app.Activity;
import android.content.Intent;
import android.content.pm.PackageInfo;
import android.content.pm.PackageManager;
import android.os.SystemClock;
import android.util.Base64;
import android.util.Log;

import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.SecureRandom;
import java.util.Arrays;
import java.util.HashSet;
import java.util.Set;

/**
 * Process-local, one-shot gate for an explicitly armed local benchmark run.
 * Nothing is persisted and there is no receiver, URL handler, arbitrary
 * profile, arbitrary world, or authentication bypass. A process restart clears
 * the challenge and closes the circuit.
 */
public final class UnattendedLocalTestGate {
    public static final String ACTION_ARM =
            "com.qcxr.qcxr.canary262.action.UNATTENDED_ARM";
    public static final String ACTION_EXECUTE =
            "com.qcxr.qcxr.canary262.action.UNATTENDED_EXECUTE";
    public static final String ACTION_CANCEL =
            "com.qcxr.qcxr.canary262.action.UNATTENDED_CANCEL";
    public static final String EXTRA_RUN_ID = "run_id";
    public static final String EXTRA_CHALLENGE = "challenge";
    public static final String EXTRA_LAUNCHER_CAMERA_PARK = "launcher_camera_park";
    public static final String EXTRA_LAUNCHER_RESOURCE_RELEASE = "launcher_resource_release";
    public static final String TAG = "QCVivecraftAutoplay";

    private static final String EXPECTED_PACKAGE = "com.qcxr.qcxr.canary262";
    private static final long ARM_TTL_MS = 60_000L;
    private static final long PENDING_TTL_MS = 5 * 60_000L;
    private static final SecureRandom RANDOM = new SecureRandom();
    private static final Object LOCK = new Object();
    private static final Set<String> ALLOWED_MILESTONES = new HashSet<>(Arrays.asList(
            "QC_AUTOPLAY_COUNTDOWN_5",
            "QC_AUTOPLAY_COUNTDOWN_CANCELLED",
            "QC_AUTOPLAY_READY",
            "QC_AUTOPLAY_PRELAUNCH_OK",
            "QC_AUTOPLAY_LAUNCH_DISPATCHED",
            "QC_AUTOPLAY_WAITING_PROFILE",
            "QC_AUTOPLAY_WAITING_WORLD",
            "QC_AUTOPLAY_CORE_HASH_FAILED",
            "QC_AUTOPLAY_PRELAUNCH_FAILED"
    ));

    private static String armedRunId;
    private static String armedChallenge;
    private static long armedExpiresAt;
    private static String pendingRunId;
    private static boolean pending;
    private static long pendingExpiresAt;
    private static String pendingLauncherCameraParkMode;
    private static String pendingLauncherResourceReleaseMode;
    private static final LauncherCameraParkPolicy.State CAMERA_PARK_STATE =
            new LauncherCameraParkPolicy.State();
    private static final LauncherResourceReleasePolicy.State RESOURCE_RELEASE_STATE =
            new LauncherResourceReleasePolicy.State();
    private static boolean circuitOpen;

    private UnattendedLocalTestGate() {
    }

    /**
     * Clears process-local benchmark state at an Activity lifecycle boundary.
     *
     * <p>The launcher Activity may be recreated without Android killing the
     * process.  Keeping a consumed ON/OFF override across that boundary could
     * affect a later manual Play, so lifecycle recreation deliberately starts
     * a fresh one-shot circuit.</p>
     */
    public static void resetForActivityLifecycle(Activity activity) {
        if(!isExpectedPackage(activity)) {
            return;
        }
        synchronized(LOCK) {
            clearArmLocked();
            clearPendingLocked();
            CAMERA_PARK_STATE.abort();
            RESOURCE_RELEASE_STATE.clear();
            circuitOpen = false;
            Log.i(TAG, "QC_AUTOPLAY_LIFECYCLE_RESET");
        }
    }

    public static boolean handleIntent(Activity activity, Intent intent) {
        if(!isExpectedPackage(activity) || intent == null) {
            return false;
        }

        String action = intent.getAction();
        if(ACTION_ARM.equals(action)) {
            arm();
            sanitize(intent);
            return true;
        }
        if(ACTION_EXECUTE.equals(action)) {
            execute(intent.getStringExtra(EXTRA_RUN_ID),
                    intent.getStringExtra(EXTRA_CHALLENGE),
                    intent.getStringExtra(EXTRA_LAUNCHER_CAMERA_PARK),
                    intent.getStringExtra(EXTRA_LAUNCHER_RESOURCE_RELEASE));
            sanitize(intent);
            return true;
        }
        if(ACTION_CANCEL.equals(action)) {
            cancel(intent.getStringExtra(EXTRA_RUN_ID));
            sanitize(intent);
            return true;
        }
        return false;
    }

    public static boolean isPending(Activity activity) {
        if(!isExpectedPackage(activity)) {
            return false;
        }
        synchronized(LOCK) {
            expireLocked(SystemClock.elapsedRealtime());
            return pending;
        }
    }

    public static boolean consumePending(Activity activity) {
        if(!isExpectedPackage(activity)) {
            return false;
        }
        synchronized(LOCK) {
            expireLocked(SystemClock.elapsedRealtime());
            if(!pending || circuitOpen) {
                return false;
            }
            String consumedRunId = pendingRunId;
            String consumedCameraParkMode = pendingLauncherCameraParkMode;
            String consumedResourceReleaseMode = pendingLauncherResourceReleaseMode;
            CAMERA_PARK_STATE.activate(consumedRunId, consumedCameraParkMode);
            RESOURCE_RELEASE_STATE.activate(consumedRunId, consumedResourceReleaseMode);
            pending = false;
            pendingRunId = null;
            pendingExpiresAt = 0L;
            pendingLauncherCameraParkMode = null;
            pendingLauncherResourceReleaseMode = null;
            circuitOpen = true;
            Log.i(TAG, "QC_AUTOPLAY_CONSUMED runId=" + consumedRunId
                    + " launcherCameraPark=" + consumedCameraParkMode
                    + " launcherResourceRelease=" + consumedResourceReleaseMode);
            return true;
        }
    }

    public static void cancelPending(Activity activity) {
        if(!isExpectedPackage(activity)) {
            return;
        }
        synchronized(LOCK) {
            clearPendingLocked();
            Log.i(TAG, "QC_AUTOPLAY_CANCELLED");
        }
    }

    public static void reportMilestone(Activity activity, String milestone) {
        if(isExpectedPackage(activity) && ALLOWED_MILESTONES.contains(milestone)) {
            Log.i(TAG, milestone);
        }
    }

    public static boolean isLauncherCameraParkEnabled(Activity activity) {
        synchronized(LOCK) {
            return CAMERA_PARK_STATE.isEnabled(isCameraParkPackage(activity));
        }
    }

    public static boolean shouldReleaseLauncherResources(Activity activity) {
        synchronized(LOCK) {
            return RESOURCE_RELEASE_STATE.shouldRelease(
                    resolveLauncherResourceReleaseIdentity(activity));
        }
    }

    public static void abortConsumed(Activity activity) {
        if(!isExpectedPackage(activity)) {
            return;
        }
        synchronized(LOCK) {
            if(!hasConsumedOverridesLocked()) {
                return;
            }
            String runId = CAMERA_PARK_STATE.getRunIdForLog();
            String mode = CAMERA_PARK_STATE.getModeForLog();
            CAMERA_PARK_STATE.abort();
            RESOURCE_RELEASE_STATE.clear();
            // The one-shot circuit deliberately stays open. A failed consumed
            // request must not be replayable within the same process.
            Log.w(TAG, "QC_AUTOPLAY_CONSUMED_ABORTED runId=" + runId
                    + " launcherCameraPark=" + mode);
        }
    }

    public static void completeConsumed(Activity activity) {
        if(!isExpectedPackage(activity)) {
            return;
        }
        synchronized(LOCK) {
            if(!hasConsumedOverridesLocked()) {
                return;
            }
            String runId = CAMERA_PARK_STATE.getRunIdForLog();
            String mode = CAMERA_PARK_STATE.getModeForLog();
            CAMERA_PARK_STATE.complete();
            RESOURCE_RELEASE_STATE.clear();
            // Completion clears only this run's process-local override. The
            // one-shot circuit remains open so the request cannot be replayed.
            Log.i(TAG, "QC_AUTOPLAY_CONSUMED_COMPLETED runId=" + runId
                    + " launcherCameraPark=" + mode);
        }
    }

    public static void reportLauncherCameraParkResult(
            Activity activity, String status, int cameraCount) {
        if(!isCameraParkPackage(activity)) {
            return;
        }
        synchronized(LOCK) {
            LauncherCameraParkPolicy.Result result =
                    CAMERA_PARK_STATE.createResult(status, cameraCount);
            if(result == null) {
                Log.w(TAG, "QC_LAUNCHER_CAMERA_PARK_RESULT_REJECTED");
                return;
            }
            Log.i(TAG, "QC_LAUNCHER_CAMERA_PARK_RESULT runId=" + result.runId
                    + " launcherCameraPark=" + result.mode
                    + " status=" + result.status
                    + " cameras=" + result.cameraCount);
        }
    }

    /** @deprecated Use {@link #reportLauncherCameraParkResult(Activity, String, int)}. */
    @Deprecated
    public static void reportLauncherCameraParkApplied(Activity activity, int disabledCameraCount) {
        reportLauncherCameraParkResult(activity,
                disabledCameraCount > 0
                        ? LauncherCameraParkPolicy.STATUS_APPLIED
                        : LauncherCameraParkPolicy.STATUS_NO_CAMERAS,
                disabledCameraCount);
    }

    private static void arm() {
        synchronized(LOCK) {
            if(circuitOpen) {
                Log.w(TAG, "QC_AUTOPLAY_CIRCUIT_OPEN");
                return;
            }
            byte[] runBytes = new byte[12];
            byte[] challengeBytes = new byte[32];
            RANDOM.nextBytes(runBytes);
            RANDOM.nextBytes(challengeBytes);
            armedRunId = encode(runBytes);
            armedChallenge = encode(challengeBytes);
            armedExpiresAt = SystemClock.elapsedRealtime() + ARM_TTL_MS;
            clearPendingLocked();
            Log.i(TAG, "QC_AUTOPLAY_CHALLENGE runId=" + armedRunId
                    + " challenge=" + armedChallenge
                    + " expiresAtElapsedMs=" + armedExpiresAt);
        }
    }

    private static void execute(String runId, String challenge, String launcherCameraParkMode,
            String launcherResourceReleaseMode) {
        synchronized(LOCK) {
            long now = SystemClock.elapsedRealtime();
            expireLocked(now);
            String normalizedCameraParkMode = normalizeCameraParkMode(launcherCameraParkMode);
            String normalizedResourceReleaseMode =
                    normalizeResourceReleaseMode(launcherResourceReleaseMode);
            boolean accepted = !circuitOpen
                    && armedRunId != null
                    && armedChallenge != null
                    && now <= armedExpiresAt
                    && constantTimeEquals(armedRunId, runId)
                    && constantTimeEquals(armedChallenge, challenge)
                    && normalizedCameraParkMode != null
                    && normalizedResourceReleaseMode != null;
            clearArmLocked();
            if(!accepted) {
                Log.w(TAG, "QC_AUTOPLAY_REJECTED");
                return;
            }
            pending = true;
            pendingRunId = runId;
            pendingExpiresAt = now + PENDING_TTL_MS;
            pendingLauncherCameraParkMode = normalizedCameraParkMode;
            pendingLauncherResourceReleaseMode = normalizedResourceReleaseMode;
            Log.i(TAG, "QC_AUTOPLAY_ACCEPTED runId=" + runId
                    + " launcherCameraPark=" + normalizedCameraParkMode
                    + " launcherResourceRelease=" + normalizedResourceReleaseMode);
        }
    }

    private static void cancel(String runId) {
        synchronized(LOCK) {
            if(pending && constantTimeEquals(pendingRunId, runId)) {
                clearPendingLocked();
                Log.i(TAG, "QC_AUTOPLAY_CANCELLED");
            } else {
                Log.w(TAG, "QC_AUTOPLAY_CANCEL_REJECTED");
            }
        }
    }

    private static void expireLocked(long now) {
        if(armedRunId != null && now > armedExpiresAt) {
            clearArmLocked();
        }
        if(pending && now > pendingExpiresAt) {
            clearPendingLocked();
            Log.w(TAG, "QC_AUTOPLAY_EXPIRED");
        }
    }

    private static void clearArmLocked() {
        armedRunId = null;
        armedChallenge = null;
        armedExpiresAt = 0L;
    }

    private static void clearPendingLocked() {
        pending = false;
        pendingRunId = null;
        pendingExpiresAt = 0L;
        pendingLauncherCameraParkMode = null;
        pendingLauncherResourceReleaseMode = null;
    }

    private static String normalizeCameraParkMode(String mode) {
        return LauncherCameraParkPolicy.normalizeMode(mode);
    }

    private static String normalizeResourceReleaseMode(String mode) {
        return LauncherResourceReleasePolicy.normalizeOptionalMode(mode);
    }

    private static boolean isExpectedPackage(Activity activity) {
        return activity != null && EXPECTED_PACKAGE.equals(activity.getPackageName());
    }

    private static boolean isCameraParkPackage(Activity activity) {
        return activity != null
                && LauncherCameraParkPolicy.isEligiblePackage(activity.getPackageName());
    }

    private static LauncherResourceReleasePolicy.BuildIdentity
            resolveLauncherResourceReleaseIdentity(Activity activity) {
        if(activity == null) {
            return LauncherResourceReleasePolicy.BuildIdentity.INELIGIBLE;
        }
        try {
            String packageName = activity.getPackageName();
            PackageInfo packageInfo = activity.getPackageManager()
                    .getPackageInfo(packageName, 0);
            return LauncherResourceReleasePolicy.resolveIdentity(
                    packageName,
                    packageInfo.getLongVersionCode(),
                    packageInfo.versionName);
        } catch(PackageManager.NameNotFoundException | RuntimeException ignored) {
            return LauncherResourceReleasePolicy.BuildIdentity.INELIGIBLE;
        }
    }

    private static boolean hasConsumedOverridesLocked() {
        return CAMERA_PARK_STATE.hasActiveOverride()
                || RESOURCE_RELEASE_STATE.hasActiveOverride();
    }

    private static String encode(byte[] value) {
        return Base64.encodeToString(value, Base64.URL_SAFE | Base64.NO_WRAP | Base64.NO_PADDING);
    }

    private static boolean constantTimeEquals(String expected, String actual) {
        if(expected == null || actual == null) {
            return false;
        }
        return MessageDigest.isEqual(
                expected.getBytes(StandardCharsets.UTF_8),
                actual.getBytes(StandardCharsets.UTF_8));
    }

    private static void sanitize(Intent intent) {
        intent.setAction(null);
        intent.removeExtra(EXTRA_RUN_ID);
        intent.removeExtra(EXTRA_CHALLENGE);
        intent.removeExtra(EXTRA_LAUNCHER_CAMERA_PARK);
        intent.removeExtra(EXTRA_LAUNCHER_RESOURCE_RELEASE);
    }
}
