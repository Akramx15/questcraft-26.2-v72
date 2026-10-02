package org.questcraft.veq.client.compat;

/** Host-only checks for exact optional-mod key mapping aliases. */
public final class VepOptionalIntegrationsSelfTest {
    private VepOptionalIntegrationsSelfTest() {
    }

    public static void main(String[] args) {
        require(VepOptionalIntegrations.Integration.XAERO_MINIMAP.matches("gui.xaero_toggle_map"),
                "Xaero minimap toggle was not recognized");
        require(VepOptionalIntegrations.Integration.XAERO_MINIMAP.matches("gui.xaero_minimap_settings"),
                "Xaero minimap settings were not recognized");
        require(VepOptionalIntegrations.Integration.XAERO_WORLD_MAP.matches("gui.xaero_enlarge_map"),
                "installed Xaero enlarge-map binding was not recognized");
        require(VepOptionalIntegrations.Integration.XAERO_WORLD_MAP.matches("gui.xaero_world_map"),
                "Xaero World Map alias was not recognized");
        require(VepOptionalIntegrations.Integration.XAERO_WORLD_MAP.matches("key.xaero_open_map"),
                "legacy Xaero World Map binding was not recognized");
        require(!VepOptionalIntegrations.Integration.XAERO_WORLD_MAP.matches("gui.xaero_toggle_map"),
                "minimap toggle must not impersonate World Map");
        require(!VepOptionalIntegrations.Integration.XAERO_MINIMAP.matches("gui.unrelated_minimap"),
                "unrelated minimap binding must not be accepted");
        System.out.println("VepOptionalIntegrationsSelfTest PASS");
    }

    private static void require(boolean condition, String message) {
        if (!condition) {
            throw new AssertionError(message);
        }
    }
}
