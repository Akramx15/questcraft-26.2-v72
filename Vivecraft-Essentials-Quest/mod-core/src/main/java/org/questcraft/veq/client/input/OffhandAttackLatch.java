package org.questcraft.veq.client.input;

/**
 * One-shot, fail-closed lifetime for a negotiated offhand-melee LT press.
 * A held trigger can neither replay an attack nor change from use to attack
 * after ownership, tracking, target, or server capability changes.
 */
final class OffhandAttackLatch {
    private State state = State.IDLE;

    boolean update(LeftUseCapture.Sample sample, boolean attackAllowed) {
        if (sample == LeftUseCapture.Sample.RELEASED) {
            this.state = State.IDLE;
            return false;
        }
        if (this.state != State.IDLE) {
            return false;
        }
        if (sample == LeftUseCapture.Sample.UNKNOWN || !attackAllowed) {
            this.state = State.SUPPRESSED_UNTIL_RELEASE;
            return false;
        }
        this.state = State.ATTACKED_UNTIL_RELEASE;
        return true;
    }

    void suppressUntilRelease() {
        this.state = State.SUPPRESSED_UNTIL_RELEASE;
    }

    State state() {
        return this.state;
    }

    enum State {
        IDLE,
        ATTACKED_UNTIL_RELEASE,
        SUPPRESSED_UNTIL_RELEASE
    }
}
