package org.vivecraft.client_vr.provider;

import java.util.Objects;
import java.util.concurrent.Executors;
import java.util.concurrent.RejectedExecutionException;
import java.util.concurrent.ScheduledExecutorService;
import java.util.concurrent.ThreadFactory;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicInteger;

public abstract class HapticScheduler implements AutoCloseable {
    private static final AtomicInteger THREAD_COUNTER = new AtomicInteger();

    private final Object lifecycleLock = new Object();
    private final ScheduledExecutorService executor;
    private boolean shutdown;

    protected HapticScheduler() {
        this(Executors.newSingleThreadScheduledExecutor(new HapticThreadFactory()));
    }

    HapticScheduler(ScheduledExecutorService executor) {
        this.executor = Objects.requireNonNull(executor);
    }

    /**
     * schedules a haptic pulse on the give controller at the given delay
     *
     * @param controller      controller to trigger on
     * @param durationSeconds duration in seconds
     * @param frequency       frequency in Hz
     * @param amplitude       strength 0.0 - 1.0
     * @param delaySeconds    delay for when to trigger in seconds
     */
    public abstract void queueHapticPulse(
        ControllerType controller, float durationSeconds, float frequency, float amplitude, float delaySeconds);

    /**
     * Schedules work while keeping shutdown mutually exclusive with a haptic callback. This ensures that once
     * {@link #shutdownNow()} returns, no callback can still access provider-owned XR handles.
     *
     * @return {@code true} when the pulse was accepted, or {@code false} when shutdown won the race
     */
    protected final boolean scheduleHapticPulse(Runnable pulse, long delay, TimeUnit unit) {
        synchronized (this.lifecycleLock) {
            if (this.shutdown) {
                return false;
            }
            try {
                this.executor.schedule(() -> {
                    synchronized (this.lifecycleLock) {
                        if (!this.shutdown) {
                            pulse.run();
                        }
                    }
                }, delay, unit);
                return true;
            } catch (RejectedExecutionException ignored) {
                // shutdownNow() may win after the initial state check.
                return false;
            }
        }
    }

    /**
     * Runs provider-local haptic work while keeping it mutually exclusive with shutdown.
     * Implementations with their own queue must use this for both queue mutation and delivery.
     *
     * @return {@code true} when the work ran, or {@code false} when shutdown won the race
     */
    protected final boolean runIfActive(Runnable work) {
        synchronized (this.lifecycleLock) {
            if (this.shutdown) {
                return false;
            }
            work.run();
            return true;
        }
    }

    protected final boolean isShutdown() {
        synchronized (this.lifecycleLock) {
            return this.shutdown;
        }
    }

    /**
     * Called exactly once while the lifecycle lock is held and after this scheduler is marked shut down.
     */
    protected void onShutdown() {
    }

    public final void shutdownNow() {
        synchronized (this.lifecycleLock) {
            if (!this.shutdown) {
                this.shutdown = true;
                try {
                    this.executor.shutdownNow();
                } finally {
                    this.onShutdown();
                }
            }
        }
    }

    @Override
    public final void close() {
        this.shutdownNow();
    }

    private static final class HapticThreadFactory implements ThreadFactory {
        @Override
        public Thread newThread(Runnable runnable) {
            Thread thread = new Thread(runnable, "Vivecraft-Haptics-" + THREAD_COUNTER.incrementAndGet());
            thread.setDaemon(true);
            return thread;
        }
    }
}
