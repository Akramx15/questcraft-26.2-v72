package org.questcraft.veq.client.input;

import java.util.Objects;
import java.util.function.Function;

/** Ordered two-hand use seam shared by production routing and Host tests. */
final class PerHandUseDispatch {
    private PerHandUseDispatch() {
    }

    static <T> Outcome dispatch(
            boolean dispatchBlocked,
            Attempt<T> main,
            Attempt<T> offhand,
            Function<T, Boolean> blocksFollowing
    ) {
        Objects.requireNonNull(main, "main attempt");
        Objects.requireNonNull(offhand, "offhand attempt");
        Objects.requireNonNull(blocksFollowing, "use operation");

        boolean blocked = dispatchBlocked;
        boolean mainDispatched = false;
        boolean offhandDispatched = false;
        if (!blocked && main.ready()) {
            mainDispatched = true;
            blocked = Boolean.TRUE.equals(blocksFollowing.apply(main.target()));
        }
        if (!blocked && offhand.ready()) {
            offhandDispatched = true;
            blocked = Boolean.TRUE.equals(blocksFollowing.apply(offhand.target()));
        }
        return new Outcome(mainDispatched, offhandDispatched, blocked);
    }

    record Attempt<T>(T target, boolean routed, boolean continuing, boolean cooldownReady) {
        boolean ready() {
            return this.target != null && this.routed && !this.continuing && this.cooldownReady;
        }
    }

    record Outcome(boolean mainDispatched, boolean offhandDispatched, boolean blocked) {
    }
}
