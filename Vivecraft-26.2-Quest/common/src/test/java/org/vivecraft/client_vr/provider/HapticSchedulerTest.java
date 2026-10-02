package org.vivecraft.client_vr.provider;

import org.junit.jupiter.api.Assertions;
import org.junit.jupiter.api.Test;

import java.util.List;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.Future;
import java.util.concurrent.ScheduledExecutorService;
import java.util.concurrent.ScheduledFuture;
import java.util.concurrent.ScheduledThreadPoolExecutor;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.TimeoutException;
import java.util.concurrent.atomic.AtomicReference;

class HapticSchedulerTest {

    @Test
    void scheduledHapticsRunOnNamedDaemonThread() throws InterruptedException {
        CountDownLatch triggered = new CountDownLatch(1);
        AtomicReference<Thread> callbackThread = new AtomicReference<>();
        TestScheduler scheduler = new TestScheduler(() -> {
            callbackThread.set(Thread.currentThread());
            triggered.countDown();
        });

        try {
            scheduler.queueHapticPulse(ControllerType.RIGHT, 0.01F, 160.0F, 1.0F, 0.0F);

            Assertions.assertTrue(triggered.await(5, TimeUnit.SECONDS));
            Assertions.assertTrue(callbackThread.get().isDaemon());
            Assertions.assertTrue(callbackThread.get().getName().startsWith("Vivecraft-Haptics-"));
        } finally {
            scheduler.close();
        }
    }

    @Test
    void shutdownIsIdempotentAndRejectsLateOrExecutorRetainedPendingHaptics() throws InterruptedException {
        CountDownLatch triggered = new CountDownLatch(1);
        RetainingScheduledExecutor executor = new RetainingScheduledExecutor();
        TestScheduler scheduler = new TestScheduler(triggered::countDown, executor);

        try {
            scheduler.queueHapticPulse(ControllerType.RIGHT, 0.01F, 160.0F, 1.0F, 0.05F);
            Assertions.assertDoesNotThrow(scheduler::shutdownNow);
            Assertions.assertDoesNotThrow(scheduler::shutdownNow);
            Assertions.assertDoesNotThrow(scheduler::close);
            Assertions.assertDoesNotThrow(() ->
                scheduler.queueHapticPulse(ControllerType.LEFT, 0.01F, 160.0F, 1.0F, 0.0F));

            Assertions.assertTrue(executor.awaitRetainedDelivery(5, TimeUnit.SECONDS),
                "the adversarial executor did not deliver the pre-shutdown task after its deadline");
            Assertions.assertEquals(1L, triggered.getCount(),
                "a pending or late haptic fired after shutdown");
        } finally {
            scheduler.close();
            executor.shutdownImmediately();
        }
    }

    @Test
    void shutdownWaitsForAnInFlightHapticBeforeReturning() throws Exception {
        CountDownLatch entered = new CountDownLatch(1);
        CountDownLatch release = new CountDownLatch(1);
        TestScheduler scheduler = new TestScheduler(() -> {
            entered.countDown();
            try {
                release.await();
            } catch (InterruptedException interruptedException) {
                Thread.currentThread().interrupt();
            }
        });
        ExecutorService closer = Executors.newSingleThreadExecutor();

        try {
            scheduler.queueHapticPulse(ControllerType.RIGHT, 0.01F, 160.0F, 1.0F, 0.0F);
            Assertions.assertTrue(entered.await(5, TimeUnit.SECONDS));

            Future<?> closeFuture = closer.submit(scheduler::shutdownNow);
            Assertions.assertThrows(TimeoutException.class, () -> closeFuture.get(100, TimeUnit.MILLISECONDS));
            release.countDown();
            Assertions.assertDoesNotThrow(() -> closeFuture.get(5, TimeUnit.SECONDS));
        } finally {
            release.countDown();
            scheduler.close();
            closer.shutdownNow();
        }
    }

    private static final class TestScheduler extends HapticScheduler {
        private final Runnable pulse;

        private TestScheduler(Runnable pulse) {
            this.pulse = pulse;
        }

        private TestScheduler(Runnable pulse, ScheduledExecutorService executor) {
            super(executor);
            this.pulse = pulse;
        }

        @Override
        public void queueHapticPulse(
            ControllerType controller, float durationSeconds, float frequency, float amplitude, float delaySeconds)
        {
            this.scheduleHapticPulse(this.pulse, (long) (delaySeconds * 1_000_000.0F), TimeUnit.MICROSECONDS);
        }
    }

    /**
     * Deliberately retains already-scheduled delayed work when shutdownNow() is requested. This lets the test prove,
     * without a timing-only sleep, that HapticScheduler's lifecycle guard rejects a callback delivered after its due
     * time even if an executor fails to cancel it.
     */
    private static final class RetainingScheduledExecutor extends ScheduledThreadPoolExecutor {
        private final CountDownLatch retainedDelivery = new CountDownLatch(1);

        private RetainingScheduledExecutor() {
            super(1, runnable -> {
                Thread thread = new Thread(runnable, "Retained-Haptic-Test");
                thread.setDaemon(true);
                return thread;
            });
            this.setExecuteExistingDelayedTasksAfterShutdownPolicy(true);
        }

        @Override
        public ScheduledFuture<?> schedule(Runnable command, long delay, TimeUnit unit) {
            return super.schedule(() -> {
                try {
                    command.run();
                } finally {
                    this.retainedDelivery.countDown();
                }
            }, delay, unit);
        }

        @Override
        public List<Runnable> shutdownNow() {
            super.shutdown();
            return List.of();
        }

        private boolean awaitRetainedDelivery(long timeout, TimeUnit unit) throws InterruptedException {
            return this.retainedDelivery.await(timeout, unit);
        }

        private void shutdownImmediately() {
            super.shutdownNow();
        }
    }
}
