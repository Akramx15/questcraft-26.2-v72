package org.questcraft.veq.client.radial;

/**
 * Identity-scoped client inventory session plus its last trusted state id.
 *
 * <p>Level, player, inventory, and menu are intentionally compared by
 * reference. A reconnect or respawn must never let a static Grip transaction
 * or marker attach itself to a new client inventory that happens to contain
 * the same items.</p>
 */
final class InventorySessionIdentity {
    private static final int STATE_ID_MASK = 0x7FFF;
    private static final int STATE_ID_HALF_RANGE = 0x4000;

    private final Object level;
    private final Object player;
    private final Object inventory;
    private final Object menu;
    private final int stateId;

    private InventorySessionIdentity(
            Object level,
            Object player,
            Object inventory,
            Object menu,
            int stateId
    ) {
        this.level = level;
        this.player = player;
        this.inventory = inventory;
        this.menu = menu;
        this.stateId = stateId & STATE_ID_MASK;
    }

    static InventorySessionIdentity capture(
            Object level,
            Object player,
            Object inventory,
            Object menu,
            int stateId
    ) {
        if (level == null || player == null || inventory == null || menu == null) {
            return null;
        }
        return new InventorySessionIdentity(level, player, inventory, menu, stateId);
    }

    boolean sameOwner(InventorySessionIdentity other) {
        return other != null &&
                this.level == other.level &&
                this.player == other.player &&
                this.inventory == other.inventory &&
                this.menu == other.menu;
    }

    boolean accepts(InventorySessionIdentity current) {
        return sameOwner(current) && stateDistanceTo(current.stateId) < STATE_ID_HALF_RANGE;
    }

    boolean advancedTo(InventorySessionIdentity current) {
        if (!sameOwner(current)) {
            return false;
        }
        int distance = stateDistanceTo(current.stateId);
        return distance > 0 && distance < STATE_ID_HALF_RANGE;
    }

    private int stateDistanceTo(int currentStateId) {
        return (currentStateId - this.stateId) & STATE_ID_MASK;
    }
}
