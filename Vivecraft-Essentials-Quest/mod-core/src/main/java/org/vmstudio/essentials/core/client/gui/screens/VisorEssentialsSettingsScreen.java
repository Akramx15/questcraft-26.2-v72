package org.vmstudio.essentials.core.client.gui.screens;

import net.minecraft.client.gui.GuiGraphicsExtractor;
import net.minecraft.client.gui.components.Button;
import net.minecraft.client.gui.components.CycleButton;
import net.minecraft.client.gui.screens.Screen;
import net.minecraft.network.chat.Component;
import org.jetbrains.annotations.NotNull;
import org.vmstudio.essentials.core.client.config.QuickActionDisplayMode;
import org.vmstudio.essentials.core.client.config.WristHudMetric;
import org.vmstudio.essentials.core.client.config.WristHudPosition;
import org.vmstudio.essentials.core.client.config.WristUiConfig;
import org.vmstudio.visor.api.compatibility.mcversion.McScreen;

import java.util.Arrays;

/** Settings page exposed through Visor's Addons menu. */
public final class VisorEssentialsSettingsScreen extends McScreen {
    private static final int BUTTON_HEIGHT = 20;
    private static final int ROW_GAP = 4;

    private final Screen previousScreen;
    private final WristUiConfig config = WristUiConfig.getInstance();

    public VisorEssentialsSettingsScreen(@NotNull Screen previousScreen) {
        super(Component.translatable("visor_essentials.options.wrist.title"));
        this.previousScreen = previousScreen;
    }

    @Override
    protected void init() {
        int gap = 8;
        int buttonWidth = Math.min(190, (width - 30 - gap) / 2);
        int totalWidth = buttonWidth * 2 + gap;
        int left = (width - totalWidth) / 2;
        int right = left + buttonWidth + gap;
        int y = 44;

        addRenderableWidget(
                CycleButton.builder(
                                QuickActionDisplayMode::displayName,
                                config.quickActionDisplayMode()
                        )
                        .withValues(Arrays.asList(QuickActionDisplayMode.values()))
                        .create(
                                left,
                                y,
                                buttonWidth,
                                BUTTON_HEIGHT,
                                Component.translatable(
                                        "visor_essentials.options.wrist.custom_buttons"
                                ),
                                (button, value) -> config.setQuickActionDisplayMode(value)
                        )
        );
        addRenderableWidget(
                CycleButton.onOffBuilder(config.showPotionEffects()).create(
                        right,
                        y,
                        buttonWidth,
                        BUTTON_HEIGHT,
                        Component.translatable(
                                "visor_essentials.options.wrist.potion_effects"
                        ),
                        (button, value) -> config.setShowPotionEffects(value)
                )
        );

        y += BUTTON_HEIGHT + ROW_GAP;
        addRenderableWidget(
                CycleButton.onOffBuilder(config.armInventoryEnabled()).create(
                        left,
                        y,
                        totalWidth,
                        BUTTON_HEIGHT,
                        Component.translatable(
                                "visor_essentials.options.wrist.arm_inventory"
                        ),
                        (button, value) -> config.setArmInventoryEnabled(value)
                )
        );

        y += BUTTON_HEIGHT + ROW_GAP;
        addRenderableWidget(
                CycleButton.onOffBuilder(config.quickActionsOpenArmInventory()).create(
                        left,
                        y,
                        totalWidth,
                        BUTTON_HEIGHT,
                        Component.translatable(
                                "visor_essentials.options.wrist.quick_actions_open_inventory"
                        ),
                        (button, value) ->
                                config.setQuickActionsOpenArmInventory(value)
                )
        );

        y += BUTTON_HEIGHT + ROW_GAP + 8;
        for (WristHudMetric metric : WristHudMetric.values()) {
            addRenderableWidget(
                    CycleButton.onOffBuilder(config.isVisible(metric)).create(
                            left,
                            y,
                            buttonWidth,
                            BUTTON_HEIGHT,
                            metric.visibilityLabel(),
                            (button, value) -> config.setVisible(metric, value)
                    )
            );
            addRenderableWidget(
                    CycleButton.builder(
                                    WristHudPosition::displayName,
                                    config.position(metric)
                            )
                            .withValues(Arrays.asList(WristHudPosition.values()))
                            .create(
                                    right,
                                    y,
                                    buttonWidth,
                                    BUTTON_HEIGHT,
                                    metric.positionLabel(),
                                    (button, value) -> config.setPosition(metric, value)
                            )
            );
            y += BUTTON_HEIGHT + ROW_GAP;
        }

        int bottomY = height - 28;
        addRenderableWidget(
                Button.builder(
                                Component.translatable("controls.reset"),
                                button -> {
                                    config.reset();
                                    minecraft.gui.setScreen(
                                            new VisorEssentialsSettingsScreen(previousScreen)
                                    );
                                }
                        )
                        .bounds(left, bottomY, buttonWidth, BUTTON_HEIGHT)
                        .build()
        );
        addRenderableWidget(
                Button.builder(
                                Component.translatable("gui.done"),
                                button -> onClose()
                        )
                        .bounds(right, bottomY, buttonWidth, BUTTON_HEIGHT)
                        .build()
        );
    }

    @Override
    public void onClose() {
        minecraft.gui.setScreen(previousScreen);
    }

    @Override
    public void render(GuiGraphicsExtractor graphics,
                       int mouseX,
                       int mouseY,
                       float partialTick) {
        renderBackground(graphics);
        graphics.centeredText(font, title, width / 2, 15, 0xFFFFFFFF);
        graphics.centeredText(
                font,
                Component.translatable("visor_essentials.options.wrist.description"),
                width / 2,
                29,
                0xFFAAAAAA
        );
        super.render(graphics, mouseX, mouseY, partialTick);
    }
}
