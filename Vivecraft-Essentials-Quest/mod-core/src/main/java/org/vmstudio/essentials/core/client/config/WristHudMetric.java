package org.vmstudio.essentials.core.client.config;

import net.minecraft.network.chat.Component;
import org.jetbrains.annotations.NotNull;

public enum WristHudMetric {
    HEALTH("health"),
    HUNGER("hunger"),
    ARMOR("armor"),
    EXPERIENCE("experience");

    private final String translationSuffix;

    WristHudMetric(@NotNull String translationSuffix) {
        this.translationSuffix = translationSuffix;
    }

    public @NotNull Component visibilityLabel() {
        return Component.translatable(
                "visor_essentials.options.wrist.show_" + translationSuffix
        );
    }

    public @NotNull Component positionLabel() {
        return Component.translatable(
                "visor_essentials.options.wrist.position_" + translationSuffix
        );
    }
}
