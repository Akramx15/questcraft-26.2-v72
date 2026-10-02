package org.questcraft.veq.client.radial;

public final class OffhandAnchorStateSelfTest {
    private OffhandAnchorStateSelfTest() {
    }

    public static void main(String[] args) {
        Object level = new Object();
        Object player = new Object();
        Object inventory = new Object();
        Object menu = new Object();
        InventorySessionIdentity session = InventorySessionIdentity.capture(
                level, player, inventory, menu, 41);
        InventorySessionIdentity nextState = InventorySessionIdentity.capture(
                level, player, inventory, menu, 42);

        OffhandAnchorState<TestItem> state = new OffhandAnchorState<>();
        require(state.actualSlot(session, item("pickaxe", 1, 10),
                OffhandAnchorStateSelfTest::sameLogicalItem) == -1,
                "unconfirmed offhand has no fake marker");
        state.confirm(session, 5, item("pickaxe", 1, 10));
        require(state.actualSlot(nextState, item("pickaxe", 64, 999),
                OffhandAnchorStateSelfTest::sameLogicalItem) == 5,
                "count and durability changes retain the logical item marker");
        require(state.actualSlot(nextState, item("blocks", 1, 0),
                OffhandAnchorStateSelfTest::sameLogicalItem) == -1,
                "external offhand change clears the stale marker");
        require(state.actualSlot(nextState, item("pickaxe", 1, 10),
                OffhandAnchorStateSelfTest::sameLogicalItem) == -1,
                "cleared marker cannot reappear from stale history");

        state.confirm(session, 5, item("pickaxe", 1, 10));
        InventorySessionIdentity otherLevel = InventorySessionIdentity.capture(
                new Object(), player, inventory, menu, 42);
        require(state.actualSlot(otherLevel, item("pickaxe", 1, 10),
                OffhandAnchorStateSelfTest::sameLogicalItem) == -1,
                "world identity changes clear the marker");

        state.confirm(session, 5, item("pickaxe", 1, 10));
        InventorySessionIdentity otherPlayer = InventorySessionIdentity.capture(
                level, new Object(), new Object(), new Object(), 0);
        require(state.actualSlot(otherPlayer, item("pickaxe", 1, 10),
                OffhandAnchorStateSelfTest::sameLogicalItem) == -1,
                "disconnect/reconnect player identity cannot inherit a marker");

        state.confirm(session, 5, item("pickaxe", 1, 10));
        InventorySessionIdentity otherMenu = InventorySessionIdentity.capture(
                level, player, inventory, new Object(), 42);
        require(state.actualSlot(otherMenu, item("pickaxe", 1, 10),
                OffhandAnchorStateSelfTest::sameLogicalItem) == -1,
                "inventory menu identity changes clear the marker");

        InventorySessionIdentity wrapStart = InventorySessionIdentity.capture(
                level, player, inventory, menu, 32767);
        InventorySessionIdentity wrapNext = InventorySessionIdentity.capture(
                level, player, inventory, menu, 0);
        state.confirm(wrapStart, 2, item("shield", 1, 20));
        require(state.actualSlot(wrapNext, item("shield", 1, 21),
                OffhandAnchorStateSelfTest::sameLogicalItem) == 2,
                "state-id wrap remains within the same live inventory session");
        require(wrapStart.advancedTo(wrapNext),
                "wrapped state id is a valid server advance");
    }

    private static TestItem item(String id, int count, int damage) {
        return new TestItem(id, count, damage);
    }

    private static boolean sameLogicalItem(TestItem actual, TestItem expected) {
        return actual.id().equals(expected.id());
    }

    private static void require(boolean condition, String message) {
        if (!condition) {
            throw new AssertionError(message);
        }
    }

    private record TestItem(String id, int count, int damage) {
    }
}
