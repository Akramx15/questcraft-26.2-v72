package org.vivecraft.client_vr.provider.openxr;

import java.util.Locale;
import java.util.function.LongConsumer;
import java.util.function.LongSupplier;

/**
 * Lab-only policy for keeping a stopped Quest OpenXR session inexpensive but responsive.
 *
 * <p>{@code VISIBLE} and {@code FOCUSED} are deliberately active states: neither one requests
 * a polling delay. The stopped-session delay is armed only after a session which reached a
 * running state reports {@code STOPPING}, and remains armed while that session is {@code IDLE}.
 * This distinguishes an ordinary background handoff from the initial pre-READY IDLE state.</p>
 */
final class QuestOpenXRBackgroundPolicy {

    static final long STOPPED_SESSION_POLL_INTERVAL_NANOS = 50_000_000L;

    private static final String LAB_INSTANCE_SUFFIX =
        "/android/data/com.qcxr.qcxr.canary262/files/instances/26.2";

    enum SessionState {
        UNKNOWN,
        IDLE,
        READY,
        SYNCHRONIZED,
        VISIBLE,
        FOCUSED,
        STOPPING,
        LOSS_PENDING,
        EXITING
    }

    private final boolean androidRuntime;
    private final boolean labInstance;
    private boolean questSystem;
    private boolean sessionWasRunning;
    private boolean stoppedSession;
    private SessionState sessionState = SessionState.UNKNOWN;

    QuestOpenXRBackgroundPolicy(boolean androidRuntime, String gameDirectory) {
        this.androidRuntime = androidRuntime;
        this.labInstance = isLabInstancePath(gameDirectory);
    }

    void setSystemName(String systemName) {
        this.questSystem = isQuestSystemName(systemName);
    }

    boolean isEnabled() {
        return this.androidRuntime && this.labInstance && this.questSystem;
    }

    void onSessionState(SessionState state) {
        this.sessionState = state == null ? SessionState.UNKNOWN : state;
        switch (this.sessionState) {
            case READY, SYNCHRONIZED, VISIBLE, FOCUSED -> {
                this.sessionWasRunning = true;
                this.stoppedSession = false;
            }
            case STOPPING -> this.stoppedSession = this.sessionWasRunning;
            case LOSS_PENDING, EXITING -> {
                this.sessionWasRunning = false;
                this.stoppedSession = false;
            }
            case UNKNOWN -> this.stoppedSession = false;
            case IDLE -> {
                // Preserve a STOPPING latch, but never arm from the initial IDLE state alone.
            }
        }
    }

    long stoppedSessionPollDelayNanos(boolean sessionRunning) {
        return shouldThrottleStoppedSession(sessionRunning) ? STOPPED_SESSION_POLL_INTERVAL_NANOS : 0L;
    }

    void parkStoppedSession(boolean sessionRunning, LongConsumer parker) {
        parkStoppedSession(sessionRunning, System::nanoTime, parker);
    }

    /**
     * Parks for the complete stopped-session interval without consuming the
     * caller's interrupt status. {@link java.util.concurrent.locks.LockSupport}
     * returns immediately while that status is set, so a single call would
     * otherwise turn every later background poll into a busy loop.
     */
    void parkStoppedSession(
        boolean sessionRunning,
        LongSupplier nanoTime,
        LongConsumer parker)
    {
        long delayNanos = stoppedSessionPollDelayNanos(sessionRunning);
        if (delayNanos <= 0L) {
            return;
        }

        long startedAt = nanoTime.getAsLong();
        long remaining = delayNanos;
        boolean restoreInterrupt = Thread.interrupted();
        try {
            while (remaining > 0L) {
                parker.accept(remaining);
                restoreInterrupt |= Thread.interrupted();
                remaining = delayNanos - (nanoTime.getAsLong() - startedAt);
            }
        } finally {
            if (restoreInterrupt) {
                Thread.currentThread().interrupt();
            }
        }
    }

    boolean shouldThrottleStoppedSession(boolean sessionRunning) {
        return isEnabled() && !sessionRunning && this.stoppedSession &&
            (this.sessionState == SessionState.STOPPING || this.sessionState == SessionState.IDLE);
    }

    boolean shouldKeepVrRunning(boolean sessionRunning) {
        return shouldThrottleStoppedSession(sessionRunning);
    }

    boolean isResumedSession(boolean sessionRunning) {
        return isEnabled() && sessionRunning && switch (this.sessionState) {
            case READY, SYNCHRONIZED, VISIBLE, FOCUSED -> true;
            default -> false;
        };
    }

    boolean isTerminalSessionState() {
        return this.sessionState == SessionState.LOSS_PENDING ||
            this.sessionState == SessionState.EXITING ||
            this.sessionState == SessionState.UNKNOWN;
    }

    boolean shouldSkipHeavyRender(boolean sessionRunning, boolean frameBegun, boolean shouldRender) {
        if (!isEnabled()) {
            return false;
        }
        if (shouldThrottleStoppedSession(sessionRunning)) {
            return true;
        }
        // A running frame with shouldRender=false must still be ended, just without rendered layers.
        return sessionRunning && frameBegun && !shouldRender;
    }

    static boolean isLabInstancePath(String gameDirectory) {
        if (gameDirectory == null) {
            return false;
        }
        String normalized = gameDirectory.trim().replace('\\', '/').toLowerCase(Locale.ROOT);
        while (normalized.endsWith("/") && !normalized.isEmpty()) {
            normalized = normalized.substring(0, normalized.length() - 1);
        }
        return normalized.endsWith(LAB_INSTANCE_SUFFIX);
    }

    static boolean isQuestSystemName(String systemName) {
        return systemName != null && systemName.toLowerCase(Locale.ROOT).contains("quest");
    }
}
