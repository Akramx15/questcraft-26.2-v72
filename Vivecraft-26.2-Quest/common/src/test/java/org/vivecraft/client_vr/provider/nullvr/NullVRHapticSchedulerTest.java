package org.vivecraft.client_vr.provider.nullvr;

import org.junit.jupiter.api.Assertions;
import org.junit.jupiter.api.Test;

import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import java.util.concurrent.Future;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.TimeoutException;
import java.util.concurrent.atomic.AtomicInteger;

class NullVRHapticSchedulerTest {

    @Test
    void activeSchedulerEmitsDueHapticsUntilTheyExpire() {
        List<NullVRHapticScheduler.Haptic> pending = new ArrayList<>();
        NullVRHapticScheduler scheduler = new NullVRHapticScheduler(pending);
        AtomicInteger emitted = new AtomicInteger();

        try {
            Assertions.assertTrue(scheduler.enqueueHaptic(haptic(100L, 10L)));
            Assertions.assertTrue(scheduler.drainHaptics(100L, ignored -> emitted.incrementAndGet()));
            Assertions.assertEquals(0, emitted.get());
            Assertions.assertEquals(1, pending.size());

            Assertions.assertTrue(scheduler.drainHaptics(101L, ignored -> emitted.incrementAndGet()));
            Assertions.assertEquals(1, emitted.get());
            Assertions.assertEquals(1, pending.size());

            Assertions.assertTrue(scheduler.drainHaptics(111L, ignored -> emitted.incrementAndGet()));
            Assertions.assertEquals(2, emitted.get());
            Assertions.assertTrue(pending.isEmpty());
        } finally {
            scheduler.close();
        }
    }

    @Test
    void shutdownClearsPendingAndRejectsLateNullVrHaptics() {
        List<NullVRHapticScheduler.Haptic> pending = new ArrayList<>();
        NullVRHapticScheduler scheduler = new NullVRHapticScheduler(pending);
        AtomicInteger emitted = new AtomicInteger();

        Assertions.assertTrue(scheduler.enqueueHaptic(haptic(1_000L, 10L)));
        Assertions.assertEquals(1, pending.size());

        scheduler.shutdownNow();

        Assertions.assertTrue(pending.isEmpty());
        Assertions.assertFalse(scheduler.enqueueHaptic(haptic(0L, 10L)));
        Assertions.assertFalse(scheduler.drainHaptics(2_000L, ignored -> emitted.incrementAndGet()));
        Assertions.assertEquals(0, emitted.get());
        Assertions.assertTrue(pending.isEmpty());
    }

    @Test
    void enqueueAndShutdownAreAtomic() throws Exception {
        BlockingAddList pending = new BlockingAddList();
        NullVRHapticScheduler scheduler = new NullVRHapticScheduler(pending);
        ExecutorService workers = Executors.newFixedThreadPool(2);
        CountDownLatch shutdownStarted = new CountDownLatch(1);

        try {
            Future<Boolean> enqueue = workers.submit(() -> scheduler.enqueueHaptic(haptic(1_000L, 10L)));
            Assertions.assertTrue(pending.addEntered.await(5, TimeUnit.SECONDS));

            Future<?> shutdown = workers.submit(() -> {
                shutdownStarted.countDown();
                scheduler.shutdownNow();
            });
            Assertions.assertTrue(shutdownStarted.await(5, TimeUnit.SECONDS));
            Assertions.assertThrows(TimeoutException.class, () -> shutdown.get(100, TimeUnit.MILLISECONDS),
                "shutdown returned while an enqueue was still inside the active lifecycle");

            pending.releaseAdd.countDown();
            Assertions.assertTrue(enqueue.get(5, TimeUnit.SECONDS));
            Assertions.assertDoesNotThrow(() -> shutdown.get(5, TimeUnit.SECONDS));
            Assertions.assertTrue(pending.isEmpty(), "shutdown did not clear the in-flight enqueue");
            Assertions.assertFalse(scheduler.enqueueHaptic(haptic(0L, 10L)));
        } finally {
            pending.releaseAdd.countDown();
            scheduler.close();
            workers.shutdownNow();
        }
    }

    @Test
    void shutdownWaitsForInFlightDrainAndPreventsLaterDelivery() throws Exception {
        List<NullVRHapticScheduler.Haptic> pending = new ArrayList<>();
        NullVRHapticScheduler scheduler = new NullVRHapticScheduler(pending);
        ExecutorService workers = Executors.newFixedThreadPool(2);
        CountDownLatch emitterEntered = new CountDownLatch(1);
        CountDownLatch releaseEmitter = new CountDownLatch(1);
        CountDownLatch shutdownStarted = new CountDownLatch(1);
        AtomicInteger emitted = new AtomicInteger();

        try {
            Assertions.assertTrue(scheduler.enqueueHaptic(haptic(0L, 10L)));
            Future<Boolean> drain = workers.submit(() -> scheduler.drainHaptics(1L, ignored -> {
                emitted.incrementAndGet();
                emitterEntered.countDown();
                awaitUninterruptibly(releaseEmitter);
            }));
            Assertions.assertTrue(emitterEntered.await(5, TimeUnit.SECONDS));

            Future<?> shutdown = workers.submit(() -> {
                shutdownStarted.countDown();
                scheduler.shutdownNow();
            });
            Assertions.assertTrue(shutdownStarted.await(5, TimeUnit.SECONDS));
            Assertions.assertThrows(TimeoutException.class, () -> shutdown.get(100, TimeUnit.MILLISECONDS),
                "shutdown returned while a NullVR haptic was still being emitted");

            releaseEmitter.countDown();
            Assertions.assertTrue(drain.get(5, TimeUnit.SECONDS));
            Assertions.assertDoesNotThrow(() -> shutdown.get(5, TimeUnit.SECONDS));
            Assertions.assertEquals(1, emitted.get());
            Assertions.assertTrue(pending.isEmpty());

            Assertions.assertFalse(scheduler.drainHaptics(20L, ignored -> emitted.incrementAndGet()));
            Assertions.assertEquals(1, emitted.get());
        } finally {
            releaseEmitter.countDown();
            scheduler.close();
            workers.shutdownNow();
        }
    }

    private static NullVRHapticScheduler.Haptic haptic(long startTime, long durationMillis) {
        return new NullVRHapticScheduler.Haptic(0, startTime, durationMillis, 160.0F, 1.0F);
    }

    private static void awaitUninterruptibly(CountDownLatch latch) {
        boolean interrupted = false;
        while (true) {
            try {
                latch.await();
                break;
            } catch (InterruptedException ignored) {
                interrupted = true;
            }
        }
        if (interrupted) {
            Thread.currentThread().interrupt();
        }
    }

    private static final class BlockingAddList extends ArrayList<NullVRHapticScheduler.Haptic> {
        private final CountDownLatch addEntered = new CountDownLatch(1);
        private final CountDownLatch releaseAdd = new CountDownLatch(1);

        @Override
        public boolean add(NullVRHapticScheduler.Haptic haptic) {
            this.addEntered.countDown();
            awaitUninterruptibly(this.releaseAdd);
            return super.add(haptic);
        }
    }
}
