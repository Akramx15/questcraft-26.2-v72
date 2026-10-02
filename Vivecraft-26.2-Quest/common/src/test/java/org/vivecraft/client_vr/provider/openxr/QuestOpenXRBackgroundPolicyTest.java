package org.vivecraft.client_vr.provider.openxr;

import org.junit.jupiter.api.Assertions;
import org.junit.jupiter.api.Test;

import java.util.concurrent.atomic.AtomicLong;
import java.util.concurrent.atomic.AtomicInteger;

class QuestOpenXRBackgroundPolicyTest {

    private static final String LAB_GAME_DIRECTORY =
        "/storage/emulated/0/Android/data/com.qcxr.qcxr.canary262/files/instances/26.2";
    private static final String STABLE_GAME_DIRECTORY =
        "/storage/emulated/0/Android/data/com.qcxr.qcxr.dev262/files/instances/26.2";

    @Test
    void eligibilityRequiresAndroidQuestAndExactLabInstance() {
        QuestOpenXRBackgroundPolicy enabled = policy(true, LAB_GAME_DIRECTORY, "Oculus Quest3");
        Assertions.assertTrue(enabled.isEnabled());

        QuestOpenXRBackgroundPolicy normalized = policy(
            true,
            "C:\\storage\\Android\\data\\com.qcxr.qcxr.canary262\\files\\instances\\26.2\\",
            "Meta Quest 3");
        Assertions.assertTrue(normalized.isEnabled());

        Assertions.assertFalse(policy(false, LAB_GAME_DIRECTORY, "Meta Quest 3").isEnabled());
        Assertions.assertFalse(policy(true, LAB_GAME_DIRECTORY, "SteamVR/OpenXR").isEnabled());
        Assertions.assertFalse(policy(true, STABLE_GAME_DIRECTORY, "Meta Quest 3").isEnabled());
        Assertions.assertFalse(policy(
            true,
            LAB_GAME_DIRECTORY.replace("canary262", "canary262.lookalike"),
            "Meta Quest 3").isEnabled());
        Assertions.assertFalse(policy(
            true,
            LAB_GAME_DIRECTORY + "-copy",
            "Meta Quest 3").isEnabled());
    }

    @Test
    void initialIdleNeverArmsTheStoppedSessionDelay() {
        QuestOpenXRBackgroundPolicy policy = enabledPolicy();

        policy.onSessionState(QuestOpenXRBackgroundPolicy.SessionState.IDLE);

        Assertions.assertEquals(0L, policy.stoppedSessionPollDelayNanos(false));
        Assertions.assertFalse(policy.shouldKeepVrRunning(false));
        Assertions.assertFalse(policy.shouldSkipHeavyRender(false, false, true));
    }

    @Test
    void focusedVisibleAndSynchronizedNeverRequestAPollDelay() {
        QuestOpenXRBackgroundPolicy policy = enabledPolicy();
        policy.onSessionState(QuestOpenXRBackgroundPolicy.SessionState.READY);

        for (QuestOpenXRBackgroundPolicy.SessionState state : new QuestOpenXRBackgroundPolicy.SessionState[]{
            QuestOpenXRBackgroundPolicy.SessionState.SYNCHRONIZED,
            QuestOpenXRBackgroundPolicy.SessionState.VISIBLE,
            QuestOpenXRBackgroundPolicy.SessionState.FOCUSED
        }) {
            policy.onSessionState(state);
            Assertions.assertEquals(0L, policy.stoppedSessionPollDelayNanos(true), state.name());
            Assertions.assertEquals(0L, policy.stoppedSessionPollDelayNanos(false), state.name());
            Assertions.assertFalse(policy.shouldKeepVrRunning(false), state.name());
            Assertions.assertFalse(policy.shouldSkipHeavyRender(true, true, true), state.name());
        }
    }

    @Test
    void stoppingThenIdlePollsAtTwentyHertzAndReadyResumesImmediately() {
        QuestOpenXRBackgroundPolicy policy = enabledPolicy();
        policy.onSessionState(QuestOpenXRBackgroundPolicy.SessionState.READY);
        policy.onSessionState(QuestOpenXRBackgroundPolicy.SessionState.FOCUSED);
        policy.onSessionState(QuestOpenXRBackgroundPolicy.SessionState.VISIBLE);
        policy.onSessionState(QuestOpenXRBackgroundPolicy.SessionState.SYNCHRONIZED);

        policy.onSessionState(QuestOpenXRBackgroundPolicy.SessionState.STOPPING);
        Assertions.assertEquals(0L, policy.stoppedSessionPollDelayNanos(true),
            "an active frame loop must never be delayed");
        Assertions.assertEquals(
            QuestOpenXRBackgroundPolicy.STOPPED_SESSION_POLL_INTERVAL_NANOS,
            policy.stoppedSessionPollDelayNanos(false));
        Assertions.assertTrue(policy.shouldKeepVrRunning(false),
            "VR must remain initialized so xrPollEvent can observe READY");
        Assertions.assertTrue(policy.shouldSkipHeavyRender(false, false, true));

        policy.onSessionState(QuestOpenXRBackgroundPolicy.SessionState.IDLE);
        Assertions.assertEquals(
            QuestOpenXRBackgroundPolicy.STOPPED_SESSION_POLL_INTERVAL_NANOS,
            policy.stoppedSessionPollDelayNanos(false));

        policy.onSessionState(QuestOpenXRBackgroundPolicy.SessionState.READY);
        Assertions.assertEquals(0L, policy.stoppedSessionPollDelayNanos(true));
        Assertions.assertEquals(0L, policy.stoppedSessionPollDelayNanos(false));
        Assertions.assertFalse(policy.shouldSkipHeavyRender(true, true, true));
    }

    @Test
    void lossAndExitNeverMasqueradeAsBackgroundIdle() {
        for (QuestOpenXRBackgroundPolicy.SessionState terminal : new QuestOpenXRBackgroundPolicy.SessionState[]{
            QuestOpenXRBackgroundPolicy.SessionState.LOSS_PENDING,
            QuestOpenXRBackgroundPolicy.SessionState.EXITING
        }) {
            QuestOpenXRBackgroundPolicy policy = enabledPolicy();
            policy.onSessionState(QuestOpenXRBackgroundPolicy.SessionState.FOCUSED);
            policy.onSessionState(QuestOpenXRBackgroundPolicy.SessionState.STOPPING);
            policy.onSessionState(terminal);
            Assertions.assertEquals(0L, policy.stoppedSessionPollDelayNanos(false), terminal.name());
            Assertions.assertFalse(policy.shouldKeepVrRunning(false), terminal.name());
        }
    }

    @Test
    void shouldRenderFalseSkipsOnlyAValidRunningLabQuestFrame() {
        QuestOpenXRBackgroundPolicy policy = enabledPolicy();
        policy.onSessionState(QuestOpenXRBackgroundPolicy.SessionState.VISIBLE);

        Assertions.assertTrue(policy.shouldSkipHeavyRender(true, true, false));
        Assertions.assertFalse(policy.shouldSkipHeavyRender(true, true, true));
        Assertions.assertFalse(policy.shouldSkipHeavyRender(true, false, false));
        Assertions.assertFalse(policy.shouldSkipHeavyRender(false, true, false));

        QuestOpenXRBackgroundPolicy stable = policy(true, STABLE_GAME_DIRECTORY, "Meta Quest 3");
        stable.onSessionState(QuestOpenXRBackgroundPolicy.SessionState.VISIBLE);
        Assertions.assertFalse(stable.shouldSkipHeavyRender(true, true, false));
    }

    @Test
    void interruptedParkWaitsForTheFullIntervalAndRestoresInterruptStatus() {
        QuestOpenXRBackgroundPolicy policy = enabledPolicy();
        policy.onSessionState(QuestOpenXRBackgroundPolicy.SessionState.FOCUSED);
        policy.onSessionState(QuestOpenXRBackgroundPolicy.SessionState.STOPPING);
        AtomicLong now = new AtomicLong();
        AtomicLong totalElapsed = new AtomicLong();
        AtomicInteger parks = new AtomicInteger();

        Assertions.assertFalse(Thread.currentThread().isInterrupted());
        Thread.currentThread().interrupt();
        try {
            policy.parkStoppedSession(false, now::get, nanos -> {
                Assertions.assertFalse(Thread.currentThread().isInterrupted(),
                    "the interrupt flag must be clear while invoking an interrupt-sensitive parker");
                int attempt = parks.incrementAndGet();
                long elapsed = attempt == 1 ? 10_000_000L : nanos;
                now.addAndGet(elapsed);
                totalElapsed.addAndGet(elapsed);
                if (attempt == 1) {
                    // Model a second interrupt/spurious wake during the first park.
                    Thread.currentThread().interrupt();
                }
            });

            Assertions.assertTrue(Thread.currentThread().isInterrupted());
            Assertions.assertEquals(
                QuestOpenXRBackgroundPolicy.STOPPED_SESSION_POLL_INTERVAL_NANOS,
                totalElapsed.get());
            Assertions.assertEquals(2, parks.get(),
                "the interrupted first park must be retried for the remaining interval");
            Assertions.assertEquals(
                QuestOpenXRBackgroundPolicy.STOPPED_SESSION_POLL_INTERVAL_NANOS,
                policy.stoppedSessionPollDelayNanos(false));
            Assertions.assertTrue(policy.shouldKeepVrRunning(false));
        } finally {
            Thread.interrupted();
        }
    }

    @Test
    void spuriousWakeCannotShortenTheStoppedSessionInterval() {
        QuestOpenXRBackgroundPolicy policy = enabledPolicy();
        policy.onSessionState(QuestOpenXRBackgroundPolicy.SessionState.FOCUSED);
        policy.onSessionState(QuestOpenXRBackgroundPolicy.SessionState.STOPPING);
        AtomicLong now = new AtomicLong();
        AtomicInteger parks = new AtomicInteger();

        policy.parkStoppedSession(false, now::get, nanos -> {
            parks.incrementAndGet();
            now.addAndGet(Math.min(nanos, 7_000_000L));
        });

        Assertions.assertEquals(
            QuestOpenXRBackgroundPolicy.STOPPED_SESSION_POLL_INTERVAL_NANOS,
            now.get());
        Assertions.assertTrue(parks.get() > 1);
        Assertions.assertFalse(Thread.currentThread().isInterrupted());
    }

    private static QuestOpenXRBackgroundPolicy enabledPolicy() {
        return policy(true, LAB_GAME_DIRECTORY, "Meta Quest 3");
    }

    private static QuestOpenXRBackgroundPolicy policy(
        boolean androidRuntime, String gameDirectory, String systemName)
    {
        QuestOpenXRBackgroundPolicy policy =
            new QuestOpenXRBackgroundPolicy(androidRuntime, gameDirectory);
        policy.setSystemName(systemName);
        return policy;
    }
}
