package org.questcraft.veq.client.input;

import org.vivecraft.client_vr.provider.ControllerType;

import static org.questcraft.veq.client.input.LeftUseCapture.Sample.DOWN;
import static org.questcraft.veq.client.input.LeftUseCapture.Sample.RELEASED;

public final class AttackBreakThisHandLatchSelfTest {
    private AttackBreakThisHandLatchSelfTest() {
    }

    public static void main(String[] args) {
        AttackBreakThisHandLatch latch = new AttackBreakThisHandLatch();
        AttackBreakThisHandLatch.Outcome first =
                latch.update(ControllerType.LEFT, DOWN, true);
        require(first.held() && first.pressed() &&
                        first.controller() == ControllerType.LEFT,
                "fresh Y press retains its provider-resolved logical hand");

        AttackBreakThisHandLatch.Outcome held =
                latch.update(ControllerType.LEFT, DOWN, true);
        require(held.held() && !held.pressed(),
                "held Y continues block breaking without replaying entity attack");

        require(!latch.update(ControllerType.RIGHT, DOWN, true).held(),
                "a held button cannot jump hands after a handedness transition");
        require(!latch.update(ControllerType.LEFT, DOWN, true).held(),
                "source mismatch stays suppressed until a sampled release");
        latch.update(ControllerType.LEFT, RELEASED, true);

        require(latch.update(ControllerType.RIGHT, DOWN, true).pressed(),
                "release rearms the button for the newly resolved logical hand");
        latch.update(ControllerType.RIGHT, RELEASED, true);

        require(!latch.update(ControllerType.LEFT, DOWN, false).held(),
                "ownership loss fails closed for the whole press");
        require(!latch.update(ControllerType.LEFT, DOWN, true).held(),
                "ownership recovery cannot manufacture a fresh held press");
    }

    private static void require(boolean condition, String message) {
        if (!condition) {
            throw new AssertionError(message);
        }
    }
}
