package org.questcraft.veq.client.input;

import static org.questcraft.veq.client.input.LeftUseCapture.Sample.DOWN;
import static org.questcraft.veq.client.input.LeftUseCapture.Sample.RELEASED;
import static org.questcraft.veq.client.input.LeftUseCapture.Sample.UNKNOWN;

public final class OffhandUseSourceLatchSelfTest {
    private OffhandUseSourceLatchSelfTest() {
    }

    public static void main(String[] args) {
        runAll();
    }

    static void runAll() {
        leftTriggerRoutesAlone();
        rightButtonRoutesAlone();
        simultaneousEdgePrefersTriggerWithoutDoubleDispatch();
        secondHeldSourceCannotReplayAfterOwnerRelease();
        ownerLossFailsClosedUntilMatchingRelease();
        shutdownClearsBothSources();
    }

    private static void leftTriggerRoutesAlone() {
        OffhandUseSourceLatch latch = new OffhandUseSourceLatch();
        OffhandUseSourceLatch.Outcome down = latch.update(DOWN, true, RELEASED, true);
        require(down.route(), "left trigger routes");
        require(down.source() == OffhandUseSourceLatch.Source.LEFT_TRIGGER,
                "left trigger owns its press");
        require(!latch.update(RELEASED, true, RELEASED, true).route(),
                "left trigger release stops use");
    }

    private static void rightButtonRoutesAlone() {
        OffhandUseSourceLatch latch = new OffhandUseSourceLatch();
        OffhandUseSourceLatch.Outcome down = latch.update(RELEASED, true, DOWN, true);
        require(down.route(), "B routes");
        require(down.source() == OffhandUseSourceLatch.Source.RIGHT_B, "B owns its press");
        require(latch.update(RELEASED, true, DOWN, true).route(), "held B remains routed");
        require(!latch.update(RELEASED, true, RELEASED, true).route(), "B release stops use");
    }

    private static void simultaneousEdgePrefersTriggerWithoutDoubleDispatch() {
        OffhandUseSourceLatch latch = new OffhandUseSourceLatch();
        OffhandUseSourceLatch.Outcome edge = latch.update(DOWN, true, DOWN, true);
        require(edge.route(), "one simultaneous source routes");
        require(edge.source() == OffhandUseSourceLatch.Source.LEFT_TRIGGER,
                "established trigger wins an exact tie");
        require(latch.update(DOWN, true, DOWN, true).route(),
                "only trigger owner continues while both held");
        require(!latch.update(RELEASED, true, DOWN, true).route(),
                "held B cannot replay when trigger releases");
        require(!latch.update(RELEASED, true, RELEASED, true).route(),
                "B matching release rearms without dispatch");
        require(latch.update(RELEASED, true, DOWN, true).route(),
                "next physical B press is fresh");
    }

    private static void secondHeldSourceCannotReplayAfterOwnerRelease() {
        OffhandUseSourceLatch latch = new OffhandUseSourceLatch();
        require(latch.update(RELEASED, true, DOWN, true).route(), "B starts owner");
        require(latch.update(DOWN, true, DOWN, true).route(), "B continues while trigger is suppressed");
        require(!latch.update(DOWN, true, RELEASED, true).route(),
                "held trigger cannot take over when B releases");
        require(!latch.update(RELEASED, true, RELEASED, true).route(),
                "trigger matching release only rearms");
        require(latch.update(DOWN, true, RELEASED, true).route(),
                "next trigger press is fresh");
    }

    private static void ownerLossFailsClosedUntilMatchingRelease() {
        OffhandUseSourceLatch latch = new OffhandUseSourceLatch();
        require(latch.update(RELEASED, true, DOWN, true).route(), "B starts before loss");
        require(!latch.update(DOWN, true, UNKNOWN, false).route(),
                "action-set/tracking loss stops B and suppresses trigger");
        require(!latch.update(DOWN, true, DOWN, true).route(),
                "recovery while B is held cannot replay either source");
        require(!latch.update(DOWN, true, RELEASED, true).route(),
                "confirmed B release clears owner without trigger takeover");
        require(!latch.update(RELEASED, true, RELEASED, true).route(),
                "trigger release rearms after suppression");
    }

    private static void shutdownClearsBothSources() {
        OffhandUseSourceLatch latch = new OffhandUseSourceLatch();
        require(latch.update(RELEASED, true, DOWN, true).route(), "B owns before shutdown");
        latch.clearForShutdown();
        require(latch.owner() == null, "shutdown clears owner");
        require(latch.update(DOWN, true, RELEASED, true).route(),
                "fresh trigger routes after a new VR session");
    }

    private static void require(boolean condition, String message) {
        if (!condition) {
            throw new AssertionError(message);
        }
    }
}
