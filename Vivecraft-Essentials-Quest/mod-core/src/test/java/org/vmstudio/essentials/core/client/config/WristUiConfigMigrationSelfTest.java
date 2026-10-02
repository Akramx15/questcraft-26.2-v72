package org.vmstudio.essentials.core.client.config;

public final class WristUiConfigMigrationSelfTest {
    private WristUiConfigMigrationSelfTest() {
    }

    public static void main(String[] args) {
        require(!WristUiConfigMigration.quickActionsOpenArmInventory(null),
                "a missing legacy value must migrate to disabled");
        require(!WristUiConfigMigration.quickActionsOpenArmInventory(Boolean.FALSE),
                "an explicit disabled value must remain disabled");
        require(WristUiConfigMigration.quickActionsOpenArmInventory(Boolean.TRUE),
                "an explicit user opt-in must remain enabled");
    }

    private static void require(boolean condition, String message) {
        if (!condition) {
            throw new AssertionError(message);
        }
    }
}
