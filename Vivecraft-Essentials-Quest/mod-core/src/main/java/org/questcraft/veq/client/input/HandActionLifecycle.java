package org.questcraft.veq.client.input;

/** Identity boundary for state that must never survive a client-world lifecycle. */
final class HandActionLifecycle {
    private Identity identity;

    Transition observe(
            boolean runtimeReady,
            Object level,
            Object player,
            Object inventory,
            Object menu,
            Object gameMode,
            Object vrRuntime,
            Object vrPlayer
    ) {
        if (!runtimeReady || level == null || player == null || inventory == null ||
                menu == null || gameMode == null || vrRuntime == null || vrPlayer == null) {
            if (this.identity == null) {
                return Transition.INACTIVE;
            }
            this.identity = null;
            return Transition.LOST;
        }

        Identity next = new Identity(
                level, player, inventory, menu, gameMode, vrRuntime, vrPlayer);
        if (this.identity == null) {
            this.identity = next;
            return Transition.ENTERED;
        }
        if (!this.identity.matches(next)) {
            this.identity = next;
            return Transition.REPLACED;
        }
        return Transition.STABLE;
    }

    void deactivate() {
        this.identity = null;
    }

    enum Transition {
        INACTIVE,
        ENTERED,
        STABLE,
        REPLACED,
        LOST;

        boolean requiresReset() {
            return this == ENTERED || this == REPLACED || this == LOST;
        }

        boolean allowsRouting() {
            return this == STABLE;
        }
    }

    private record Identity(
            Object level,
            Object player,
            Object inventory,
            Object menu,
            Object gameMode,
            Object vrRuntime,
            Object vrPlayer
    ) {
        private boolean matches(Identity other) {
            return this.level == other.level && this.player == other.player &&
                    this.inventory == other.inventory && this.menu == other.menu &&
                    this.gameMode == other.gameMode && this.vrRuntime == other.vrRuntime &&
                    this.vrPlayer == other.vrPlayer;
        }
    }
}
