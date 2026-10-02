package org.questcraft.veq.client.input;

import net.minecraft.world.InteractionHand;

import static org.questcraft.veq.client.input.LeftUseCapture.Decision.NONE;
import static org.questcraft.veq.client.input.LeftUseCapture.Decision.ROUTE;
import static org.questcraft.veq.client.input.LeftUseCapture.Decision.SUPPRESS;
import static org.questcraft.veq.client.input.LeftUseCapture.Sample.DOWN;
import static org.questcraft.veq.client.input.LeftUseCapture.Sample.RELEASED;

public final class OffhandUseContinuationPolicySelfTest {
    private OffhandUseContinuationPolicySelfTest() {
    }

    public static void main(String[] args) {
        longUseSurvivesFortyTicks();
        releaseAndTrackingLossStopImmediately();
        competingMainHandStillBlocks();
    }

    private static void longUseSurvivesFortyTicks() {
        LeftUseCapture capture = new LeftUseCapture();
        require(capture.update(DOWN, true) == ROUTE, "initial food/shield/charge press routes");
        int dispatches = OffhandUseContinuationPolicy.shouldDispatchUse(true, false, true) ? 1 : 0;
        for (int tick = 1; tick <= 40; tick++) {
            boolean blocked = OffhandUseContinuationPolicy.blocksWorldUse(
                    true, true, InteractionHand.OFF_HAND, true);
            require(!blocked, "owned offhand continuation remains eligible at tick " + tick);
            require(capture.update(DOWN, !blocked) == ROUTE,
                    "held trigger remains routed at tick " + tick);
            if (OffhandUseContinuationPolicy.shouldDispatchUse(true, true, true)) {
                dispatches++;
            }
        }
        require(dispatches == 1, "long use dispatches once and then only maintains key hold");
    }

    private static void releaseAndTrackingLossStopImmediately() {
        LeftUseCapture release = new LeftUseCapture();
        require(release.update(DOWN, true) == ROUTE, "release scenario starts");
        require(release.update(RELEASED, true) == NONE, "trigger release stops use immediately");

        LeftUseCapture tracking = new LeftUseCapture();
        require(tracking.update(DOWN, true) == ROUTE, "tracking scenario starts");
        require(tracking.update(DOWN, false) == SUPPRESS, "tracking loss suppresses held use");
        require(tracking.update(DOWN, true) == SUPPRESS,
                "tracking recovery while held cannot resume the old press");
    }

    private static void competingMainHandStillBlocks() {
        require(OffhandUseContinuationPolicy.blocksWorldUse(
                        true, true, InteractionHand.MAIN_HAND, true),
                "main-hand use remains a competing owner");
        require(OffhandUseContinuationPolicy.blocksWorldUse(
                        true, true, InteractionHand.OFF_HAND, false),
                "unowned offhand use remains fail-closed");
    }

    private static void require(boolean condition, String message) {
        if (!condition) {
            throw new AssertionError(message);
        }
    }
}
