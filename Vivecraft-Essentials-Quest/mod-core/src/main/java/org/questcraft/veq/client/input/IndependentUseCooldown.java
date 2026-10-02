package org.questcraft.veq.client.input;

/** Cooldown isolated from Minecraft.rightClickDelay so right mining continues. */
final class IndependentUseCooldown {
    private int ticks;

    void tick() {
        if (this.ticks > 0) {
            this.ticks--;
        }
    }

    boolean ready() {
        return this.ticks == 0;
    }

    void arm(int delayTicks) {
        this.ticks = Math.max(0, delayTicks);
    }

    void clear() {
        this.ticks = 0;
    }
}
