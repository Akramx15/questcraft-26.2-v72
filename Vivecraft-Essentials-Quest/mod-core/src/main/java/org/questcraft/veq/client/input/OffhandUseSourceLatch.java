package org.questcraft.veq.client.input;

/**
 * Arbitrates the two physical controls that can command one logical offhand.
 *
 * <p>The source that starts a valid press owns offhand use until that same
 * source produces a confirmed release. A second held source is suppressed
 * until its own release, so releasing the owner cannot replay it as a new
 * click.</p>
 */
final class OffhandUseSourceLatch {
    private final LeftUseCapture triggerCapture = new LeftUseCapture();
    private final LeftUseCapture buttonCapture = new LeftUseCapture();
    private Source owner;

    Outcome update(
            LeftUseCapture.Sample triggerSample,
            boolean triggerWorldAllowed,
            LeftUseCapture.Sample buttonSample,
            boolean buttonWorldAllowed
    ) {
        Source ownerAtStart = this.owner;
        LeftUseCapture.Decision triggerDecision = this.triggerCapture.update(
                triggerSample,
                triggerWorldAllowed && (ownerAtStart == null || ownerAtStart == Source.LEFT_TRIGGER)
        );
        LeftUseCapture.Decision buttonDecision = this.buttonCapture.update(
                buttonSample,
                buttonWorldAllowed && (ownerAtStart == null || ownerAtStart == Source.RIGHT_B)
        );

        if (ownerAtStart == null) {
            // Preserve the established left-trigger behavior for an exact
            // simultaneous edge; B stays suppressed until it is released.
            if (triggerDecision == LeftUseCapture.Decision.ROUTE) {
                this.owner = Source.LEFT_TRIGGER;
            } else if (buttonDecision == LeftUseCapture.Decision.ROUTE) {
                this.owner = Source.RIGHT_B;
            }
        } else {
            LeftUseCapture.Decision ownerDecision = ownerAtStart == Source.LEFT_TRIGGER
                    ? triggerDecision
                    : buttonDecision;
            LeftUseCapture.Sample ownerSample = ownerAtStart == Source.LEFT_TRIGGER
                    ? triggerSample
                    : buttonSample;
            if (ownerDecision == LeftUseCapture.Decision.NONE &&
                    ownerSample == LeftUseCapture.Sample.RELEASED) {
                this.owner = null;
            }
        }

        if (this.owner == Source.LEFT_TRIGGER) {
            return new Outcome(triggerDecision == LeftUseCapture.Decision.ROUTE, this.owner);
        }
        if (this.owner == Source.RIGHT_B) {
            return new Outcome(buttonDecision == LeftUseCapture.Decision.ROUTE, this.owner);
        }
        return new Outcome(false, null);
    }

    Source owner() {
        return this.owner;
    }

    void clearForShutdown() {
        this.triggerCapture.clearForShutdown();
        this.buttonCapture.clearForShutdown();
        this.owner = null;
    }

    enum Source {
        LEFT_TRIGGER,
        RIGHT_B
    }

    record Outcome(boolean route, Source source) {
    }
}
