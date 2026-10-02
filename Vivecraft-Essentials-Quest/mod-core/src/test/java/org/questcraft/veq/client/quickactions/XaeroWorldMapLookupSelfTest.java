package org.questcraft.veq.client.quickactions;

/** Prevents the World Map action from silently becoming a Minimap toggle. */
public final class XaeroWorldMapLookupSelfTest {
    private XaeroWorldMapLookupSelfTest() {
    }

    public static void main(String[] args) {
        require(QuickActionManager.isXaeroWorldMapMapping("key.xaero_open_map"),
                "canonical Xaero World Map key");
        require(QuickActionManager.isXaeroWorldMapMapping("gui.xaero_world_map"),
                "compatible World Map alias");
        require(!QuickActionManager.isXaeroWorldMapMapping("gui.xaero_toggle_map"),
                "Minimap toggle must not impersonate World Map");
        require(!QuickActionManager.isXaeroWorldMapMapping("key.xaerominimap.open_map"),
                "explicit Minimap mapping must be excluded");
        require(!QuickActionManager.isXaeroWorldMapMapping(null),
                "null mapping must be rejected");
        System.out.println("XaeroWorldMapLookupSelfTest PASS");
    }

    private static void require(boolean condition, String message) {
        if (!condition) {
            throw new AssertionError(message);
        }
    }
}
