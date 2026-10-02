package org.questcraft.veq.client.gui;

import net.minecraft.client.gui.GuiGraphicsExtractor;
import net.minecraft.client.gui.components.Button;
import net.minecraft.client.gui.screens.Screen;
import net.minecraft.network.chat.Component;
import org.questcraft.veq.client.config.QuestButtonBindingsConfig;
import org.questcraft.veq.client.input.QuestFaceButton;

/** Standalone editor; it deliberately does not enter Wrist calibration mode. */
public final class QuestButtonBindingsScreen extends Screen {
    private static final int ROW_HEIGHT = 24;
    private final Screen parent;
    private final QuestButtonBindingsConfig config = QuestButtonBindingsConfig.getInstance();
    private boolean transactionStarted;
    private boolean completed;
    private boolean saveFailed;

    public QuestButtonBindingsScreen(Screen parent) {
        super(Component.translatable("vivecraft_essentials_quest.quest_controls"));
        this.parent = parent;
    }

    @Override
    protected void init() {
        if (!transactionStarted) {
            config.beginEditing();
            transactionStarted = true;
        }

        int center = width / 2;
        int y = 54;
        for (QuestFaceButton faceButton : QuestFaceButton.values()) {
            QuestFaceButton button = faceButton;
            addRenderableWidget(Button.builder(
                    bindingLabel(button),
                    ignored -> {
                        config.cycle(button);
                        rebuildWidgets();
                    }
            ).bounds(center - 154, y, 308, 20).build());
            y += ROW_HEIGHT;
        }

        y += 4;
        addRenderableWidget(Button.builder(
                Component.translatable("vivecraft_essentials_quest.quest_controls.personal_defaults"),
                ignored -> {
                    config.resetPersonalDefaults();
                    rebuildWidgets();
                }
        ).bounds(center - 154, y, 150, 20).build());
        addRenderableWidget(Button.builder(
                Component.translatable("vivecraft_essentials_quest.quest_controls.vivecraft_defaults"),
                ignored -> {
                    config.resetVivecraftDefaults();
                    rebuildWidgets();
                }
        ).bounds(center + 4, y, 150, 20).build());

        int bottom = Math.min(height - 28, y + ROW_HEIGHT + 8);
        addRenderableWidget(Button.builder(
                Component.translatable("vivecraft_essentials_quest.cancel"),
                ignored -> cancel()
        ).bounds(center - 154, bottom, 150, 20).build());
        Button apply = Button.builder(
                Component.translatable("vivecraft_essentials_quest.apply"),
                ignored -> apply()
        ).bounds(center + 4, bottom, 150, 20).build();
        apply.active = !config.isFutureVersionReadOnly();
        addRenderableWidget(apply);
    }

    @Override
    public void extractRenderState(
            GuiGraphicsExtractor graphics,
            int mouseX,
            int mouseY,
            float partialTick
    ) {
        extractBackground(graphics, mouseX, mouseY, partialTick);
        graphics.centeredText(font, title, width / 2, 14, 0xFFFFFFFF);
        Component hint;
        int hintColor;
        if (config.isFutureVersionReadOnly()) {
            hint = Component.literal("This config was created by a newer version and is read-only");
            hintColor = 0xFFFF8080;
        } else if (saveFailed) {
            hint = Component.literal("Could not save button bindings. Check the log and try again");
            hintColor = 0xFFFF5555;
        } else if (config.restartRequired()) {
            hint = Component.translatable("vivecraft_essentials_quest.quest_controls.hint");
            hintColor = 0xFFFFC060;
        } else {
            hint = Component.literal("Choose a button action, then Apply");
            hintColor = 0xFFB0B0B0;
        }
        graphics.centeredText(font, hint, width / 2, 31, hintColor);
        super.extractRenderState(graphics, mouseX, mouseY, partialTick);
    }

    @Override
    public void onClose() {
        cancel();
    }

    @Override
    public void removed() {
        if (!completed) {
            config.cancelEditing();
        }
        super.removed();
    }

    private Component bindingLabel(QuestFaceButton button) {
        return Component.translatable(
                "vivecraft_essentials_quest.quest_controls.binding",
                button.label(),
                Component.translatable(config.action(button).translationKey())
        );
    }

    private void apply() {
        if (config.isFutureVersionReadOnly()) {
            return;
        }
        if (!config.applyEditing()) {
            saveFailed = true;
            return;
        }
        completed = true;
        minecraft.gui.setScreen(parent);
    }

    private void cancel() {
        config.cancelEditing();
        completed = true;
        minecraft.gui.setScreen(parent);
    }
}
