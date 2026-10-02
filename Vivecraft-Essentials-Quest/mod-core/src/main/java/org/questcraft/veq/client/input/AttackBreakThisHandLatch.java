package org.questcraft.veq.client.input;

import org.vivecraft.client_vr.provider.ControllerType;

/**
 * One physical face button whose provider-resolved logical hand is retained
 * for the complete press. UNKNOWN or ownership loss suppresses the press until
 * a real release, so a held Y cannot jump between hands after reverseHands or
 * an action-set transition.
 */
final class AttackBreakThisHandLatch {
    private ControllerType activeController;
    private State state = State.IDLE;

    Outcome update(
            ControllerType controller,
            LeftUseCapture.Sample sample,
            boolean worldAllowed
    ) {
        if (sample == LeftUseCapture.Sample.RELEASED) {
            this.activeController = null;
            this.state = State.IDLE;
            return Outcome.IDLE;
        }
        if (this.state == State.SUPPRESSED_UNTIL_RELEASE) {
            return Outcome.IDLE;
        }
        if (sample == LeftUseCapture.Sample.UNKNOWN || controller == null || !worldAllowed) {
            this.activeController = null;
            this.state = State.SUPPRESSED_UNTIL_RELEASE;
            return Outcome.IDLE;
        }
        if (this.state == State.HELD) {
            if (controller != this.activeController) {
                this.activeController = null;
                this.state = State.SUPPRESSED_UNTIL_RELEASE;
                return Outcome.IDLE;
            }
            return new Outcome(controller, true, false);
        }
        this.activeController = controller;
        this.state = State.HELD;
        return new Outcome(controller, true, true);
    }

    void suppressUntilRelease() {
        this.activeController = null;
        this.state = State.SUPPRESSED_UNTIL_RELEASE;
    }

    enum State {
        IDLE,
        HELD,
        SUPPRESSED_UNTIL_RELEASE
    }

    record Outcome(ControllerType controller, boolean held, boolean pressed) {
        private static final Outcome IDLE = new Outcome(null, false, false);
    }
}
