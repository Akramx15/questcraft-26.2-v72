package org.questcraft.veq.client.radial;

import org.vivecraft.client_vr.provider.ControllerType;

/** Delayed END simulation for the reconciliation-to-render feedback seam. */
public final class GripSwapRejectionHandoffSelfTest {
    private GripSwapRejectionHandoffSelfTest() {
    }

    public static void main(String[] args) {
        GripFeedbackState feedback = new GripFeedbackState();
        GripSwapRejectionHandoff handoff = new GripSwapRejectionHandoff();
        feedback.pending(ControllerType.LEFT, 6);

        long reconciliationTime = 1_000L;
        HotbarHandState.rejected(ControllerType.LEFT, 6, reconciliationTime);
        handoff.reconciled(
                PendingSwapConfirmation.Result.REJECTED,
                ControllerType.LEFT,
                6
        );

        long delayedEnd = reconciliationTime + HotbarHandState.REJECTION_NANOS + 1L;
        require(!HotbarHandState.isRejected(ControllerType.LEFT, 6, delayedEnd),
                "the simulated END runs after legacy wall-clock feedback expired");

        GripSwapRejectionHandoff.Rejection rejection = handoff.consume();
        require(rejection != null && rejection.controller() == ControllerType.LEFT &&
                        rejection.slot() == 6,
                "reconciliation carries the exact rejected hand and slot to delayed END");
        require(feedback.rejectPending(rejection.controller(), rejection.slot()),
                "delayed END promotes the semantic event into tick-owned feedback");
        require(handoff.consume() == null, "the rejection handoff is one-shot");

        int visibleWindows = 0;
        while (feedback.rejectedSlot(ControllerType.LEFT) == 6) {
            visibleWindows++;
            require(visibleWindows <= GripFeedbackState.REJECTION_TICKS,
                    "rejection feedback cannot outlive its tick budget");
            if (feedback.tickRejected()) {
                feedback.clear();
            }
        }
        require(visibleWindows == GripFeedbackState.REJECTION_TICKS,
                "a delayed END still renders exactly four red tick windows");

        feedback.pending(ControllerType.LEFT, 4);
        handoff.reconciled(
                PendingSwapConfirmation.Result.REJECTED,
                ControllerType.RIGHT,
                4
        );
        GripSwapRejectionHandoff.Rejection otherHand = handoff.consume();
        require(otherHand != null &&
                        !feedback.rejectPending(otherHand.controller(), otherHand.slot()),
                "a rejection event cannot attach to another pending hand");
        handoff.reconciled(
                PendingSwapConfirmation.Result.REJECTED,
                ControllerType.LEFT,
                4
        );
        handoff.clear();
        require(handoff.consume() == null,
                "cancellation removes an unconsumed rejection event");
        HotbarHandState.clearTransient();
    }

    private static void require(boolean condition, String message) {
        if (!condition) {
            throw new AssertionError(message);
        }
    }
}
