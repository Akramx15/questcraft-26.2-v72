package org.vmstudio.essentials.core.client.config;

import net.minecraft.network.chat.Component;
import org.jetbrains.annotations.NotNull;

public enum QuickActionDisplayMode {
    OFF(0, "off"),
    SIX(6, "six"),
    TWELVE(12, "twelve");

    private final int visibleSlots;
    private final String translationSuffix;

    QuickActionDisplayMode(int visibleSlots, @NotNull String translationSuffix) {
        this.visibleSlots = visibleSlots;
        this.translationSuffix = translationSuffix;
    }

    public int visibleSlots() {
        return visibleSlots;
    }

    public @NotNull Component displayName() {
        return Component.translatable(
                "visor_essentials.options.wrist.custom_buttons." + translationSuffix
        );
    }
}
