package org.questcraft.veq.client.input;

import static org.questcraft.veq.client.input.LeftUseCapture.Decision.NONE;
import static org.questcraft.veq.client.input.LeftUseCapture.Decision.ROUTE;
import static org.questcraft.veq.client.input.LeftUseCapture.Decision.SUPPRESS;
import static org.questcraft.veq.client.input.LeftUseCapture.Sample.DOWN;
import static org.questcraft.veq.client.input.LeftUseCapture.Sample.RELEASED;
import static org.questcraft.veq.client.input.LeftUseCapture.Sample.UNKNOWN;

public final class LeftUseCaptureSelfTest {
    private LeftUseCaptureSelfTest() {
    }

    public static void main(String[] args) {
        normalWorldPressAndRelease();
        ownerTransitionRequiresConfirmedRelease();
        actionSetOriginAndTrackingTransitionsFailClosed();
        pressStartingUnderHigherPriorityNeverLeaks();
        unknownBeforeFirstVisiblePressNeverLeaks();
        OffhandUseSourceLatchSelfTest.runAll();
    }

    private static void normalWorldPressAndRelease() {
        LeftUseCapture capture = new LeftUseCapture();
        require(capture.update(DOWN, true) == ROUTE, "world press routes");
        require(capture.update(DOWN, true) == ROUTE, "held world press may repeat through cooldown");
        require(capture.update(RELEASED, false) == NONE, "active sampled release clears");
        require(capture.state() == LeftUseCapture.State.IDLE, "release returns idle");
    }

    private static void ownerTransitionRequiresConfirmedRelease() {
        LeftUseCapture capture = new LeftUseCapture();
        require(capture.update(DOWN, true) == ROUTE, "world starts routed");
        require(capture.update(DOWN, false) == SUPPRESS, "wrist/IMC/climb transition captures");
        require(capture.update(DOWN, true) == SUPPRESS, "leaving owner while held stays captured");
        require(capture.update(RELEASED, true) == NONE, "confirmed release clears owner capture");
        require(capture.update(DOWN, true) == ROUTE, "next physical press is fresh");
    }

    private static void actionSetOriginAndTrackingTransitionsFailClosed() {
        for (String transition : new String[]{"disabled", "origin0", "action-set", "tracking"}) {
            LeftUseCapture capture = new LeftUseCapture();
            require(capture.update(DOWN, true) == ROUTE, transition + " starts in world");
            require(capture.update(UNKNOWN, false) == SUPPRESS, transition + " becomes suppressed");
            require(capture.update(UNKNOWN, true) == SUPPRESS, transition + " unknown cannot release");
            require(capture.update(DOWN, true) == SUPPRESS, transition + " recovery while held cannot leak");
            require(capture.update(RELEASED, true) == NONE, transition + " sampled release clears");
        }
    }

    private static void pressStartingUnderHigherPriorityNeverLeaks() {
        LeftUseCapture capture = new LeftUseCapture();
        require(capture.update(DOWN, false) == SUPPRESS, "non-world press captured immediately");
        require(capture.update(UNKNOWN, false) == SUPPRESS, "inactive action set remains captured");
        require(capture.update(DOWN, true) == SUPPRESS, "re-entering world while held cannot click");
        require(capture.update(RELEASED, true) == NONE, "only confirmed release clears");
    }

    private static void unknownBeforeFirstVisiblePressNeverLeaks() {
        LeftUseCapture capture = new LeftUseCapture();
        require(capture.update(UNKNOWN, false) == SUPPRESS,
                "inactive action set latches even before a visible DOWN");
        require(capture.update(DOWN, true) == SUPPRESS,
                "held trigger cannot become fresh after action-set recovery");
        require(capture.update(RELEASED, true) == NONE, "confirmed release rearms capture");
        require(capture.update(DOWN, true) == ROUTE, "next physical press routes");
    }

    private static void require(boolean condition, String message) {
        if (!condition) {
            throw new AssertionError(message);
        }
    }
}
