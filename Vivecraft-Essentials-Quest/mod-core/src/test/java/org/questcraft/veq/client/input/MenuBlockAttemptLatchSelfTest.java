package org.questcraft.veq.client.input;

import static org.questcraft.veq.client.input.LeftUseCapture.Sample.DOWN;
import static org.questcraft.veq.client.input.LeftUseCapture.Sample.RELEASED;
import static org.questcraft.veq.client.input.LeftUseCapture.Sample.UNKNOWN;

/** Host-only regression contract for held-L2 menu packet suppression. */
public final class MenuBlockAttemptLatchSelfTest {
    private MenuBlockAttemptLatchSelfTest() {
    }

    public static void main(String[] args) {
        runAll();
    }

    static void runAll() {
        heldTriggerProducesOneAttemptUntilRelease();
        screenIdentityChangeRearmsTheAttempt();
        ownershipLossFailsClosedUntilRelease();
        lifecycleResetFailsClosedUntilRelease();
    }

    private static void heldTriggerProducesOneAttemptUntilRelease() {
        MenuBlockAttemptLatch latch = new MenuBlockAttemptLatch();
        latch.observe(DOWN, null);
        latch.observeOwnership(true, DOWN);
        require(latch.claim(), "first translated block-menu attempt routes");
        require(!latch.claim(), "held L2 cannot repeat after a use cooldown");
        latch.observe(DOWN, null);
        require(!latch.claim(), "more held frames cannot rearm the attempt");
        latch.observe(RELEASED, null);
        require(latch.claim(), "a confirmed L2 release rearms the attempt");
    }

    private static void screenIdentityChangeRearmsTheAttempt() {
        MenuBlockAttemptLatch latch = new MenuBlockAttemptLatch();
        Object worldScreen = null;
        Object containerScreen = new Object();
        latch.observe(DOWN, worldScreen);
        require(latch.claim(), "initial attempt routes");
        latch.observe(DOWN, containerScreen);
        require(latch.claim(), "a different native screen identity rearms the guard");
        require(!latch.claim(), "the new screen identity still permits only one attempt");
    }

    private static void ownershipLossFailsClosedUntilRelease() {
        MenuBlockAttemptLatch latch = new MenuBlockAttemptLatch();
        latch.observe(DOWN, null);
        latch.observeOwnership(false, DOWN);
        require(!latch.claim(), "ownership loss suppresses a hidden held press");
        latch.observe(UNKNOWN, null);
        latch.observeOwnership(false, UNKNOWN);
        latch.observe(DOWN, null);
        latch.observeOwnership(true, DOWN);
        require(!latch.claim(), "ownership recovery cannot replay held L2");
        latch.observe(RELEASED, null);
        latch.observeOwnership(true, RELEASED);
        require(latch.claim(), "release after ownership recovery rearms L2");
    }

    private static void lifecycleResetFailsClosedUntilRelease() {
        MenuBlockAttemptLatch latch = new MenuBlockAttemptLatch();
        latch.observe(DOWN, null);
        require(latch.claim(), "pre-reset attempt routes");
        latch.suppressUntilRelease();
        latch.observe(DOWN, null);
        require(!latch.claim(), "lifecycle reset suppresses held L2");
        latch.observe(RELEASED, null);
        require(latch.claim(), "post-reset release rearms L2");
    }

    private static void require(boolean condition, String message) {
        if (!condition) {
            throw new AssertionError(message);
        }
    }
}
