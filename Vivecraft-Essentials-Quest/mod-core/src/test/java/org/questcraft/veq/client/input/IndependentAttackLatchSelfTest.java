package org.questcraft.veq.client.input;

import static org.questcraft.veq.client.input.LeftUseCapture.Sample.DOWN;
import static org.questcraft.veq.client.input.LeftUseCapture.Sample.RELEASED;

public final class IndependentAttackLatchSelfTest {
    private IndependentAttackLatchSelfTest() {
    }

    public static void main(String[] args) {
        eitherSourceKeepsAttackHeld();
        blockedButtonRequiresARealRelease();
        blockedButtonCannotTakeOverFromTrigger();
    }

    private static void eitherSourceKeepsAttackHeld() {
        IndependentAttackLatch latch = new IndependentAttackLatch();
        require(latch.update(DOWN, true, DOWN, true),
                "RT and Y may route together");
        require(latch.update(RELEASED, true, DOWN, true),
                "Y keeps attack routed after RT release");
        require(latch.update(DOWN, true, RELEASED, true),
                "RT keeps attack routed after Y release");
        require(!latch.update(RELEASED, true, RELEASED, true),
                "attack releases only after both sources release");
    }

    private static void blockedButtonRequiresARealRelease() {
        IndependentAttackLatch latch = new IndependentAttackLatch();
        require(!latch.update(RELEASED, true, DOWN, false),
                "Wrist-owned Y is suppressed");
        require(!latch.update(RELEASED, true, DOWN, true),
                "closing Wrist cannot replay a held Y press");
        require(!latch.update(RELEASED, true, RELEASED, true),
                "physical release rearms without routing");
        require(latch.update(RELEASED, true, DOWN, true),
                "a new Y press routes after release");
    }

    private static void blockedButtonCannotTakeOverFromTrigger() {
        IndependentAttackLatch latch = new IndependentAttackLatch();
        require(latch.update(DOWN, true, DOWN, false),
                "RT routes while Y is UI-owned");
        require(!latch.update(RELEASED, true, DOWN, true),
                "releasing RT cannot hand attack to a previously blocked Y hold");
        require(!latch.update(RELEASED, true, RELEASED, true),
                "Y release only rearms the source");
        require(latch.update(RELEASED, true, DOWN, true),
                "fresh Y press routes normally");
    }

    private static void require(boolean condition, String message) {
        if (!condition) {
            throw new AssertionError(message);
        }
    }
}
