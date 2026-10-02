package org.questcraft.veq.client.radial;

/** Requires both stable inventory contents and an advanced container state id. */
final class PendingSwapConfirmation {
    static final int TIMEOUT_TICKS = 40;
    private int age;
    private int matchingTicks;
    private boolean pending;

    void begin() {
        this.age = 0;
        this.matchingTicks = 0;
        this.pending = true;
    }

    Result update(boolean contentsMatch, boolean serverStateAdvanced) {
        if (!this.pending) {
            return Result.NONE;
        }
        this.age++;
        this.matchingTicks = contentsMatch ? this.matchingTicks + 1 : 0;
        if (serverStateAdvanced && this.matchingTicks >= 2) {
            this.pending = false;
            return Result.CONFIRMED;
        }
        if (this.age >= TIMEOUT_TICKS) {
            this.pending = false;
            return Result.REJECTED;
        }
        return Result.PENDING;
    }

    boolean isPending() {
        return this.pending;
    }

    void clear() {
        this.pending = false;
        this.age = 0;
        this.matchingTicks = 0;
    }

    enum Result {
        NONE,
        PENDING,
        CONFIRMED,
        REJECTED
    }
}
