package org.questcraft.veq.client.input;

/** Independent edge/loss suppression for B-main-use and trigger-offhand-use. */
final class IndependentHandUseLatch {
    private final LeftUseCapture mainUse = new LeftUseCapture();
    private final LeftUseCapture offhandUse = new LeftUseCapture();

    Outcome update(
            LeftUseCapture.Sample mainSample,
            boolean mainAllowed,
            LeftUseCapture.Sample offhandSample,
            boolean offhandAllowed
    ) {
        return new Outcome(
                this.mainUse.update(mainSample, mainAllowed) == LeftUseCapture.Decision.ROUTE,
                this.offhandUse.update(offhandSample, offhandAllowed) == LeftUseCapture.Decision.ROUTE
        );
    }

    void suppressUntilRelease() {
        this.mainUse.suppressUntilRelease();
        this.offhandUse.suppressUntilRelease();
    }

    record Outcome(boolean mainUse, boolean offhandUse) {
    }
}
