package org.questcraft.veq.client.input;

import static org.questcraft.veq.client.input.LeftUseCapture.Sample.DOWN;
import static org.questcraft.veq.client.input.LeftUseCapture.Sample.RELEASED;
import static org.questcraft.veq.client.input.LeftUseCapture.Sample.UNKNOWN;

public final class OffhandAttackLatchSelfTest {
    private OffhandAttackLatchSelfTest() {
    }

    public static void main(String[] args) {
        oneAttackPerPhysicalPress();
        usePressCannotTurnIntoAttackWhileHeld();
        ownershipLossCannotReplayHeldPress();
    }

    private static void oneAttackPerPhysicalPress() {
        OffhandAttackLatch latch = new OffhandAttackLatch();
        require(latch.update(DOWN, true), "fresh negotiated press attacks");
        require(!latch.update(DOWN, true), "held LT cannot repeat attack packets");
        require(!latch.update(RELEASED, true), "release only rearms the latch");
        require(latch.update(DOWN, true), "fresh press attacks after release");
    }

    private static void usePressCannotTurnIntoAttackWhileHeld() {
        OffhandAttackLatch latch = new OffhandAttackLatch();
        require(!latch.update(DOWN, false),
                "a use/non-entity press does not attack");
        require(latch.state() == OffhandAttackLatch.State.SUPPRESSED_UNTIL_RELEASE,
                "non-attack LT press is latched away from melee");
        require(!latch.update(DOWN, true),
                "moving a held use press onto an entity cannot create an attack");
        latch.update(RELEASED, true);
        require(latch.update(DOWN, true),
                "release followed by a new entity press may attack");
    }

    private static void ownershipLossCannotReplayHeldPress() {
        OffhandAttackLatch latch = new OffhandAttackLatch();
        require(!latch.update(UNKNOWN, true),
                "unknown origin/tracking fails closed");
        require(!latch.update(DOWN, true),
                "recovering ownership cannot replay a hidden held LT press");
        latch.update(RELEASED, true);
        require(latch.update(DOWN, true),
                "only an observed release rearms after ownership loss");
        latch.suppressUntilRelease();
        require(!latch.update(DOWN, true),
                "lifecycle suppression also requires a release");
    }

    private static void require(boolean condition, String message) {
        if (!condition) {
            throw new AssertionError(message);
        }
    }
}
