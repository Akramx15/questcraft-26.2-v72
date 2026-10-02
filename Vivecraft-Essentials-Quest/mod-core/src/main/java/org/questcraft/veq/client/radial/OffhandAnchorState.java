package org.questcraft.veq.client.radial;

import java.util.function.BiPredicate;

/** Tracks where the live offhand should be visualized after a confirmed swap. */
final class OffhandAnchorState<T> {
    private int slot = -1;
    private T expected;
    private InventorySessionIdentity session;

    void confirm(InventorySessionIdentity session, int slot, T expected) {
        if (session == null || slot < 0 || expected == null) {
            clear();
            return;
        }
        this.session = session;
        this.slot = slot;
        this.expected = expected;
    }

    int actualSlot(
            InventorySessionIdentity currentSession,
            T actual,
            BiPredicate<T, T> equality
    ) {
        if (this.session == null || !this.session.accepts(currentSession) ||
                this.slot < 0 || this.expected == null || actual == null || equality == null ||
                !equality.test(actual, this.expected)) {
            clear();
            return -1;
        }
        return this.slot;
    }

    void clear() {
        this.slot = -1;
        this.expected = null;
        this.session = null;
    }
}
