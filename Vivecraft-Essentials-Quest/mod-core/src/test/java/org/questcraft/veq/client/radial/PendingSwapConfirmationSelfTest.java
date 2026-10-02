package org.questcraft.veq.client.radial;

public final class PendingSwapConfirmationSelfTest {
    private PendingSwapConfirmationSelfTest() {
    }

    public static void main(String[] args) {
        PendingSwapConfirmation state = new PendingSwapConfirmation();
        state.begin();
        require(state.update(true, false) == PendingSwapConfirmation.Result.PENDING,
                "predicted local state is not success");
        require(state.update(true, true) == PendingSwapConfirmation.Result.CONFIRMED,
                "stable contents plus server state confirms");
        require(!state.isPending(), "confirmation ends pending state");

        state.begin();
        for (int tick = 1; tick < PendingSwapConfirmation.TIMEOUT_TICKS; tick++) {
            require(state.update(false, tick > 1) == PendingSwapConfirmation.Result.PENDING,
                    "mismatched server state stays pending until timeout");
        }
        require(state.update(false, true) == PendingSwapConfirmation.Result.REJECTED,
                "timeout rejects without success haptic");
    }

    private static void require(boolean condition, String message) {
        if (!condition) {
            throw new AssertionError(message);
        }
    }
}
