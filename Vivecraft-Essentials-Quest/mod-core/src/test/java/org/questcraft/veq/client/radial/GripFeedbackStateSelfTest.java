package org.questcraft.veq.client.radial;

import org.vivecraft.client_vr.provider.ControllerType;

public final class GripFeedbackStateSelfTest {
    private GripFeedbackStateSelfTest() {
    }

    public static void main(String[] args) {
        GripFeedbackState feedback = new GripFeedbackState();
        require(!feedback.blocksSelection(), "a fresh surface accepts one release selection");

        feedback.pending(ControllerType.LEFT, 6);
        require(feedback.isPending(), "server-confirmed SWAP feedback starts pending");
        require(feedback.blocksSelection(),
                "pending feedback is read-only and cannot repeat the transaction");
        require(feedback.controller() == ControllerType.LEFT && feedback.slot() == 6,
                "pending feedback retains its exact logical hand and slot");

        feedback.rejected(ControllerType.LEFT, 6);
        require(feedback.isRejected(), "failed confirmation becomes rejection feedback");
        require(feedback.rejectedSlot(ControllerType.LEFT) == 6,
                "the rejected hand renders from the tick-owned feedback state");
        require(feedback.rejectedSlot(ControllerType.RIGHT) == -1,
                "rejection feedback cannot leak to the other logical hand");
        for (int tick = 1; tick < GripFeedbackState.REJECTION_TICKS; tick++) {
            require(!feedback.tickRejected(),
                    "red feedback remains visible for the short rejection window");
            require(feedback.blocksSelection(),
                    "red feedback cannot dispatch another selection");
            require(feedback.rejectedSlot(ControllerType.LEFT) == 6,
                    "wall-clock stalls cannot shorten the four-tick render window");
        }
        require(feedback.tickRejected(), "red feedback closes after four ticks");

        feedback.clear();
        require(!feedback.blocksSelection(), "closing feedback resets the read-only latch");
        require(feedback.rejectedSlot(ControllerType.LEFT) == -1,
                "closing feedback removes the rendered rejection");
    }

    private static void require(boolean condition, String message) {
        if (!condition) {
            throw new AssertionError(message);
        }
    }
}
