package org.questcraft.veq.client.input;

/**
 * One-shot guard for the logical-left block-menu protocol translation.
 *
 * <p>A held trigger is intentionally allowed to repeat ordinary item uses,
 * but a translated {@code OFF_HAND -> MAIN_HAND} block-menu interaction must
 * produce at most one packet. A confirmed trigger release or a different
 * native screen identity rearms the guard. Unknown input and ownership loss
 * fail closed until release.</p>
 */
final class MenuBlockAttemptLatch {
    private State state = State.READY;
    private Object screenIdentity;
    private boolean screenObserved;

    void observe(LeftUseCapture.Sample sample, Object currentScreen) {
        if (!this.screenObserved) {
            this.screenIdentity = currentScreen;
            this.screenObserved = true;
        } else if (this.screenIdentity != currentScreen) {
            this.screenIdentity = currentScreen;
            this.state = State.READY;
        }

        if (sample == LeftUseCapture.Sample.RELEASED) {
            this.state = State.READY;
        }
    }

    void observeOwnership(boolean worldAllowed, LeftUseCapture.Sample sample) {
        if (!worldAllowed && sample != LeftUseCapture.Sample.RELEASED) {
            suppressUntilRelease();
        }
    }

    boolean claim() {
        if (this.state != State.READY) {
            return false;
        }
        this.state = State.ATTEMPTED;
        return true;
    }

    void suppressUntilRelease() {
        this.state = State.SUPPRESSED_UNTIL_RELEASE;
    }

    State state() {
        return this.state;
    }

    enum State {
        READY,
        ATTEMPTED,
        SUPPRESSED_UNTIL_RELEASE
    }
}
