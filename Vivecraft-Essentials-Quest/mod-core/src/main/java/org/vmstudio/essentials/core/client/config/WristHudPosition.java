package org.vmstudio.essentials.core.client.config;

import net.minecraft.network.chat.Component;
import org.jetbrains.annotations.NotNull;

public enum WristHudPosition {
    TOP("top"),
    BOTTOM("bottom");

    private final String translationSuffix;

    WristHudPosition(@NotNull String translationSuffix) {
        this.translationSuffix = translationSuffix;
    }

    public @NotNull Component displayName() {
        return Component.translatable(
                "visor_essentials.options.wrist.position." + translationSuffix
        );
    }
}
