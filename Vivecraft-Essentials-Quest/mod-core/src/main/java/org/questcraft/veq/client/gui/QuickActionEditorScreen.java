package org.questcraft.veq.client.gui;

import net.minecraft.client.Minecraft;
import net.minecraft.client.gui.GuiGraphicsExtractor;
import net.minecraft.client.gui.components.Button;
import net.minecraft.client.gui.components.EditBox;
import net.minecraft.client.gui.components.Tooltip;
import net.minecraft.client.gui.screens.Screen;
import net.minecraft.core.registries.BuiltInRegistries;
import net.minecraft.network.chat.Component;
import net.minecraft.resources.Identifier;
import net.minecraft.world.item.ItemStack;
import org.jetbrains.annotations.Nullable;
import org.questcraft.veq.client.quickactions.QuickActionDefinition;
import org.questcraft.veq.client.quickactions.QuickActionManager;
import org.questcraft.veq.client.quickactions.QuickActionType;

/** Head-mounted editor for a VEP quick-action slot. */
public final class QuickActionEditorScreen extends Screen {
    private static final int PANEL_WIDTH = 500;
    private static final int PANEL_HEIGHT = 280;

    private final int slotIndex;
    private final @Nullable Screen returnTo;
    private final QuickActionManager manager = QuickActionManager.getInstance();
    private QuickActionType actionType;
    private String displayName;
    private String iconItemId;
    private String actionValue;
    private @Nullable EditBox nameBox;
    private @Nullable EditBox valueBox;
    private @Nullable EditBox iconBox;
    private @Nullable Button typeButton;
    private @Nullable Button saveButton;
    private @Nullable Component error;
    private int panelX;
    private int panelY;
    private int panelWidth;
    private int panelHeight;

    private QuickActionEditorScreen(int slotIndex, @Nullable Screen returnTo) {
        super(Component.translatable("vivecraft_essentials_quest.quick_action.edit"));
        if (slotIndex < 0 || slotIndex >= QuickActionManager.SLOT_COUNT) {
            throw new IndexOutOfBoundsException("Quick action slot: " + slotIndex);
        }
        this.slotIndex = slotIndex;
        this.returnTo = returnTo;
        QuickActionDefinition action = manager.getAction(slotIndex);
        this.actionType = action.type() == QuickActionType.KEYBIND
                ? QuickActionType.KEYBIND
                : QuickActionType.COMMAND;
        this.displayName = action.displayName();
        this.iconItemId = action.iconItemId().isBlank()
                ? QuickActionManager.DEFAULT_ICON_ID
                : action.iconItemId();
        this.actionValue = action.value();
    }

    public static void open(int slotIndex, @Nullable Screen returnTo) {
        Minecraft.getInstance().gui.setScreen(new QuickActionEditorScreen(slotIndex, returnTo));
    }

    @Override
    protected void init() {
        panelWidth = Math.min(PANEL_WIDTH, Math.max(300, width - 20));
        panelHeight = Math.min(PANEL_HEIGHT, Math.max(250, height - 20));
        panelX = (width - panelWidth) / 2;
        panelY = Math.max(5, (height - panelHeight) / 2);
        int labelX = panelX + 18;
        int fieldX = panelX + 126;
        int fieldWidth = panelWidth - 144;
        int y = panelY + 36;

        typeButton = addRenderableWidget(Button.builder(typeLabel(), ignored -> {
            actionType = actionType == QuickActionType.COMMAND
                    ? QuickActionType.KEYBIND
                    : QuickActionType.COMMAND;
            typeButton.setMessage(typeLabel());
            refreshValueHint();
            validate();
        }).bounds(fieldX, y, fieldWidth, 20).tooltip(Tooltip.create(Component.translatable(
                "vivecraft_essentials_quest.quick_action.type.help"
        ))).build());

        y += 38;
        nameBox = new EditBox(
                font, fieldX, y, fieldWidth, 20,
                Component.translatable("vivecraft_essentials_quest.quick_action.name")
        );
        nameBox.setMaxLength(QuickActionDefinition.MAX_NAME_LENGTH);
        nameBox.setValue(displayName);
        nameBox.setResponder(value -> {
            displayName = value;
            validate();
        });
        addRenderableWidget(nameBox);

        y += 38;
        valueBox = new EditBox(
                font, fieldX, y, fieldWidth, 20,
                Component.translatable("vivecraft_essentials_quest.quick_action.value")
        );
        valueBox.setMaxLength(QuickActionDefinition.MAX_VALUE_LENGTH);
        valueBox.setValue(actionType == QuickActionType.COMMAND && !actionValue.isBlank()
                ? "/" + actionValue
                : actionValue);
        valueBox.setResponder(value -> {
            actionValue = actionType == QuickActionType.COMMAND
                    ? QuickActionDefinition.normalizeCommand(value)
                    : value.strip();
            validate();
        });
        addRenderableWidget(valueBox);
        refreshValueHint();

        y += 38;
        iconBox = new EditBox(
                font, fieldX, y, fieldWidth, 20,
                Component.translatable("vivecraft_essentials_quest.quick_action.icon")
        );
        iconBox.setMaxLength(QuickActionDefinition.MAX_ITEM_ID_LENGTH);
        iconBox.setValue(iconItemId);
        iconBox.setResponder(value -> {
            iconItemId = value.strip();
            validate();
        });
        addRenderableWidget(iconBox);

        int bottomY = panelY + panelHeight - 31;
        addRenderableWidget(Button.builder(
                Component.translatable("vivecraft_essentials_quest.quick_action.clear"),
                ignored -> {
                    manager.clearAction(slotIndex);
                    closeEditor();
                }
        ).bounds(labelX, bottomY, 90, 20).build());
        addRenderableWidget(Button.builder(
                Component.translatable("vivecraft_essentials_quest.cancel"),
                ignored -> closeEditor()
        ).bounds(width / 2 - 45, bottomY, 90, 20).build());
        saveButton = addRenderableWidget(Button.builder(
                Component.translatable("vivecraft_essentials_quest.apply"),
                ignored -> save()
        ).bounds(panelX + panelWidth - 108, bottomY, 90, 20).build());
        validate();
        setInitialFocus(nameBox);
    }

    private Component typeLabel() {
        return Component.translatable(actionType == QuickActionType.COMMAND
                ? "vivecraft_essentials_quest.quick_action.command"
                : "vivecraft_essentials_quest.quick_action.keybind");
    }

    private void refreshValueHint() {
        if (valueBox != null) {
            valueBox.setHint(Component.translatable(actionType == QuickActionType.COMMAND
                    ? "vivecraft_essentials_quest.quick_action.command.hint"
                    : "vivecraft_essentials_quest.quick_action.keybind.hint"));
        }
    }

    private void validate() {
        error = null;
        if (actionValue.isBlank()) {
            error = Component.translatable("vivecraft_essentials_quest.quick_action.value.required");
        } else if (actionType == QuickActionType.KEYBIND
                && manager.findKeyMapping(actionValue) == null) {
            error = Component.translatable("vivecraft_essentials_quest.quick_action.keybind.missing");
        } else if (!iconItemId.isBlank() && !manager.isRegisteredItem(iconItemId)) {
            error = Component.translatable("vivecraft_essentials_quest.quick_action.icon.missing");
        }
        if (saveButton != null) {
            saveButton.active = error == null;
        }
    }

    private void save() {
        validate();
        if (error != null) {
            return;
        }
        manager.setAction(slotIndex, new QuickActionDefinition(
                actionType,
                displayName,
                iconItemId,
                actionValue
        ));
        closeEditor();
    }

    @Override
    public void extractRenderState(GuiGraphicsExtractor graphics,
                                   int mouseX,
                                   int mouseY,
                                   float partialTick) {
        graphics.fill(panelX, panelY, panelX + panelWidth, panelY + panelHeight, 0xE0181818);
        graphics.outline(panelX, panelY, panelWidth, panelHeight, 0xFF777777);
        graphics.centeredText(font, title, width / 2, panelY + 12, 0xFFFFFFFF);
        int labelX = panelX + 18;
        int y = panelY + 42;
        graphics.text(font, Component.translatable(
                "vivecraft_essentials_quest.quick_action.type"), labelX, y, 0xFFE0E0E0, false);
        y += 38;
        graphics.text(font, Component.translatable(
                "vivecraft_essentials_quest.quick_action.name"), labelX, y, 0xFFE0E0E0, false);
        y += 38;
        graphics.text(font, Component.translatable(
                "vivecraft_essentials_quest.quick_action.value"), labelX, y, 0xFFE0E0E0, false);
        y += 38;
        graphics.text(font, Component.translatable(
                "vivecraft_essentials_quest.quick_action.icon"), labelX, y, 0xFFE0E0E0, false);
        super.extractRenderState(graphics, mouseX, mouseY, partialTick);
        renderChosenIcon(graphics);
        if (error != null) {
            graphics.centeredText(font, error, width / 2, panelY + panelHeight - 49, 0xFFFF7777);
        }
    }

    private void renderChosenIcon(GuiGraphicsExtractor graphics) {
        if (iconBox == null) {
            return;
        }
        Identifier id = Identifier.tryParse(iconItemId);
        if (id == null) {
            return;
        }
        BuiltInRegistries.ITEM.getOptional(id).ifPresent(item -> {
            ItemStack stack = item.getDefaultInstance();
            graphics.item(stack, iconBox.getX() + iconBox.getWidth() - 19, iconBox.getY() + 2);
        });
    }

    @Override
    public void tick() {
        validate();
    }

    @Override
    public void onClose() {
        closeEditor();
    }

    private void closeEditor() {
        if (minecraft != null) {
            minecraft.gui.setScreen(returnTo);
        }
    }

    @Override
    public boolean isPauseScreen() {
        return true;
    }
}
