package org.questcraft.veq.client.input;

/**
 * Independent fail-closed captures for the right trigger and a configurable
 * face-button attack source.
 *
 * <p>Keeping one capture per physical source is important: releasing either
 * source must not cancel the other, and a button held while a UI owns its hand
 * must not become a fresh attack when that UI closes.</p>
 */
final class IndependentAttackLatch {
    private final LeftUseCapture trigger = new LeftUseCapture();
    private final LeftUseCapture button = new LeftUseCapture();

    boolean update(
            LeftUseCapture.Sample triggerSample,
            boolean triggerAllowed,
            LeftUseCapture.Sample buttonSample,
            boolean buttonAllowed
    ) {
        boolean triggerRoutes = this.trigger.update(triggerSample, triggerAllowed) ==
                LeftUseCapture.Decision.ROUTE;
        boolean buttonRoutes = this.button.update(buttonSample, buttonAllowed) ==
                LeftUseCapture.Decision.ROUTE;
        return triggerRoutes || buttonRoutes;
    }

    void suppressUntilRelease() {
        this.trigger.suppressUntilRelease();
        this.button.suppressUntilRelease();
    }
}
