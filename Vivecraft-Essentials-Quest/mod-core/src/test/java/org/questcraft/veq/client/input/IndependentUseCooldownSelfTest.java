package org.questcraft.veq.client.input;

public final class IndependentUseCooldownSelfTest {
    private IndependentUseCooldownSelfTest() {
    }

    public static void main(String[] args) {
        IndependentUseCooldown cooldown = new IndependentUseCooldown();
        require(cooldown.ready(), "starts ready");
        cooldown.arm(4);
        for (int tick = 0; tick < 3; tick++) {
            cooldown.tick();
            require(!cooldown.ready(), "no duplicate use packet before delay");
        }
        cooldown.tick();
        require(cooldown.ready(), "left use becomes ready independently");
        cooldown.arm(10);
        cooldown.clear();
        require(cooldown.ready(), "lifecycle clear releases cooldown");
    }

    private static void require(boolean condition, String message) {
        if (!condition) {
            throw new AssertionError(message);
        }
    }
}
