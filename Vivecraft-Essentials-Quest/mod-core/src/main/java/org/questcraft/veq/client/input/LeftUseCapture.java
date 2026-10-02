package org.questcraft.veq.client.input;

/**
 * Fail-closed lifetime for one handed offhand-trigger press.
 *
 * <p>Once an observed press loses its action set, origin, priority owner, or
 * tracking, it cannot become a fresh world click. Only an active, sampled
 * release clears the suppression latch.</p>
 */
final class LeftUseCapture {
    private State state = State.IDLE;

    Decision update(Sample sample, boolean worldAllowed) {
        if (sample == Sample.RELEASED) {
            this.state = State.IDLE;
            return Decision.NONE;
        }

        if (this.state == State.SUPPRESSED_UNTIL_RELEASE) {
            return Decision.SUPPRESS;
        }

        if (sample == Sample.UNKNOWN) {
            // UNKNOWN can hide a physical press while an action set, origin,
            // tracking pose, or higher-priority owner is unavailable. Latch
            // even from IDLE so a held trigger cannot appear as a fresh DOWN
            // when eligibility returns.
            this.state = State.SUPPRESSED_UNTIL_RELEASE;
            return Decision.SUPPRESS;
        }

        if (!worldAllowed) {
            this.state = State.SUPPRESSED_UNTIL_RELEASE;
            return Decision.SUPPRESS;
        }

        this.state = State.WORLD_HELD;
        return Decision.ROUTE;
    }

    State state() {
        return this.state;
    }

    void suppressUntilRelease() {
        this.state = State.SUPPRESSED_UNTIL_RELEASE;
    }

    void clearForShutdown() {
        this.state = State.IDLE;
    }

    enum Sample {
        DOWN,
        RELEASED,
        UNKNOWN
    }

    enum Decision {
        NONE,
        ROUTE,
        SUPPRESS
    }

    enum State {
        IDLE,
        WORLD_HELD,
        SUPPRESSED_UNTIL_RELEASE
    }
}
