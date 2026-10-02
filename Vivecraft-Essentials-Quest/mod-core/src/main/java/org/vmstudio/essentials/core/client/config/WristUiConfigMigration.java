package org.vmstudio.essentials.core.client.config;

import org.jetbrains.annotations.Nullable;

/** Pure migration helpers kept separate from Minecraft's config lifecycle. */
final class WristUiConfigMigration {
    private WristUiConfigMigration() {
    }

    /**
     * Missing legacy values migrate to the safe v0.1.4 default: B does not
     * force the arm inventory open. An explicit user opt-in is preserved.
     */
    static boolean quickActionsOpenArmInventory(@Nullable Boolean storedValue) {
        return Boolean.TRUE.equals(storedValue);
    }
}
