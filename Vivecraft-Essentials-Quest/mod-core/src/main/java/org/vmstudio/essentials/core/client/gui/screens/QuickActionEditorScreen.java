package org.vmstudio.essentials.core.client.gui.screens;

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
import org.vmstudio.essentials.core.client.quickactions.QuickActionDefinition;
import org.vmstudio.essentials.core.client.quickactions.QuickActionManager;
import org.vmstudio.essentials.core.client.quickactions.QuickActionType;
import org.vmstudio.visor.api.compatibility.mcversion.McScreen;

/**
 * Head-mounted editor for one of VisorEssentials' twelve inventory quick actions.
 *
 * <p>This is an ordinary Minecraft screen on purpose: Visor presents ordinary
 * screens on the HMD and supplies its VR keyboard to the edit boxes. Closing
 * the screen returns to {@code null}, allowing the wrist inventory overlay to
 * become visible again on the next tick.</p>
 */
public final class QuickActionEditorScreen extends McScreen {
    private static final int PANEL_WIDTH = 500;
    private static final int PANEL_HEIGHT = 302;
    private static final int FIELD_HEIGHT = 20;
    private static final int BUTTON_HEIGHT = 20;
    private static final int LABEL_COLOR = 0xFFE0E0E0;
    private static final int MUTED_COLOR = 0xFFAAAAAA;
    private static final int ERROR_COLOR = 0xFFFF7777;
    private static final int PANEL_COLOR = 0xE0181818;
    private static final int PANEL_BORDER = 0xFF777777;

    private final int slotIndex;
    private final @Nullable Screen returnTo;
    private final QuickActionManager manager = QuickActionManager.getInstance();

    private QuickActionType actionType;
    private String displayName;
    private String iconItemId;
    private String commandValue;
    private String keybindValue;
    private @Nullable Component statusMessage;

    private @Nullable EditBox nameBox;
    private @Nullable EditBox commandBox;
    private @Nullable Button keybindButton;
    private @Nullable Button iconButton;
    private @Nullable Button saveButton;

    private int panelX;
    private int panelY;
    private int panelWidth;
    private int panelHeight;

    private QuickActionEditorScreen(int slotIndex, @Nullable Screen returnTo) {
        super(Component.literal("Edit Quick Action"));
        if (slotIndex < 0 || slotIndex >= QuickActionManager.SLOT_COUNT) {
            throw new IndexOutOfBoundsException("Quick action slot: " + slotIndex);
        }
        this.slotIndex = slotIndex;
        this.returnTo = returnTo;

        QuickActionDefinition current = manager.getAction(slotIndex);
        this.actionType = current.type() == QuickActionType.KEYBIND
                ? QuickActionType.KEYBIND
                : QuickActionType.COMMAND;
        this.displayName = current.displayName();
        this.iconItemId = current.iconItemId().isBlank()
                ? QuickActionManager.DEFAULT_ICON_ID
                : current.iconItemId();
        this.commandValue = current.type() == QuickActionType.COMMAND
                ? current.value()
                : "";
        this.keybindValue = current.type() == QuickActionType.KEYBIND
                ? current.value()
                : "";
    }

    /** Opens a slot editor from the wrist inventory and returns there on close. */
    public static void open(int slotIndex) {
        open(slotIndex, Minecraft.getInstance().gui.screen());
    }

    /** Opens a slot editor and returns to the supplied screen on close. */
    public static void open(int slotIndex, @Nullable Screen returnTo) {
        Minecraft.getInstance().gui.setScreen(
                new QuickActionEditorScreen(slotIndex, returnTo)
        );
    }

    @Override
    protected void init() {
        panelWidth = Math.min(PANEL_WIDTH, Math.max(280, width - 20));
        panelHeight = Math.min(PANEL_HEIGHT, Math.max(270, height - 20));
        panelX = (width - panelWidth) / 2;
        panelY = Math.max(5, (height - panelHeight) / 2);

        int contentX = panelX + 20;
        int contentWidth = panelWidth - 40;
        int fieldX = contentX + 108;
        int fieldWidth = Math.max(120, contentWidth - 108);
        int y = panelY + 42;

        addRenderableWidget(Button.builder(
                typeLabel(),
                ignored -> cycleType()
        ).bounds(fieldX, y - 5, fieldWidth, BUTTON_HEIGHT).tooltip(
                Tooltip.create(Component.literal(
                        "Choose whether this button sends a command or presses a Minecraft keybind"
                ))
        ).build());

        y += 38;
        nameBox = new EditBox(
                font,
                fieldX,
                y - 5,
                fieldWidth,
                FIELD_HEIGHT,
                Component.literal("Quick action name")
        );
        nameBox.setMaxLength(QuickActionDefinition.MAX_NAME_LENGTH);
        nameBox.setHint(Component.literal("Shown in the button tooltip"));
        nameBox.setValue(displayName);
        nameBox.setResponder(value -> displayName = value);
        addRenderableWidget(nameBox);

        y += 38;
        if (actionType == QuickActionType.COMMAND) {
            commandBox = new EditBox(
                    font,
                    fieldX,
                    y - 5,
                    fieldWidth,
                    FIELD_HEIGHT,
                    Component.literal("Command")
            );
            commandBox.setMaxLength(QuickActionDefinition.MAX_VALUE_LENGTH);
            commandBox.setHint(Component.literal("/home, /spawn, or another command"));
            commandBox.setValue(commandValue.isBlank() ? "" : "/" + commandValue);
            // Keep the working value in the same slash-free form used by the
            // persisted definition. Otherwise rebuilding this screen after a
            // Command -> Keybind -> Command toggle would prepend another slash.
            commandBox.setResponder(value ->
                    commandValue = QuickActionDefinition.normalizeCommand(value)
            );
            addRenderableWidget(commandBox);
            keybindButton = null;
        } else {
            commandBox = null;
            keybindButton = addRenderableWidget(Button.builder(
                    keybindLabel(),
                    ignored -> minecraft.gui.setScreen(
                            new QuickActionKeybindPickerScreen(this, keybindValue)
                    )
            ).bounds(fieldX, y - 5, fieldWidth, BUTTON_HEIGHT).tooltip(
                    Tooltip.create(Component.literal(
                            "Choose from the keybinds listed in Minecraft's Controls menu"
                    ))
            ).build());
        }

        y += 38;
        iconButton = addRenderableWidget(Button.builder(
                Component.literal("Choose Item Icon"),
                ignored -> minecraft.gui.setScreen(
                        new QuickActionIconPickerScreen(this, iconItemId)
                )
        ).bounds(fieldX, y - 5, fieldWidth, BUTTON_HEIGHT).build());
        refreshIconButtonTooltip();

        int bottomY = panelY + panelHeight - 34;
        int gap = 6;
        int buttonWidth = Math.max(64, (contentWidth - gap * 3) / 4);
        saveButton = addRenderableWidget(Button.builder(
                Component.literal("Save"),
                ignored -> save()
        ).bounds(contentX, bottomY, buttonWidth, BUTTON_HEIGHT).build());
        Button clearButton = addRenderableWidget(Button.builder(
                Component.literal("Clear"),
                ignored -> clear()
        ).bounds(contentX + buttonWidth + gap, bottomY, buttonWidth, BUTTON_HEIGHT).tooltip(
                Tooltip.create(Component.literal("Remove this quick action"))
        ).build());
        clearButton.active = manager.isConfigured(slotIndex);
        addRenderableWidget(Button.builder(
                Component.literal("Choose Keybind"),
                ignored -> {
                    cacheFields();
                    actionType = QuickActionType.KEYBIND;
                    minecraft.gui.setScreen(new QuickActionKeybindPickerScreen(this, keybindValue));
                }
        ).bounds(contentX + (buttonWidth + gap) * 2, bottomY, buttonWidth, BUTTON_HEIGHT).tooltip(
                Tooltip.create(Component.literal("Jump directly to the keybind list"))
        ).build());
        addRenderableWidget(Button.builder(
                Component.literal("Cancel"),
                ignored -> closeEditor()
        ).bounds(contentX + (buttonWidth + gap) * 3, bottomY, buttonWidth, BUTTON_HEIGHT).build());

        updateSaveState();
        setInitialFocus(nameBox);
    }

    private void cycleType() {
        cacheFields();
        actionType = actionType == QuickActionType.COMMAND
                ? QuickActionType.KEYBIND
                : QuickActionType.COMMAND;
        statusMessage = null;
        rebuildWidgets();
    }

    private void cacheFields() {
        if (nameBox != null) {
            displayName = nameBox.getValue();
        }
        if (commandBox != null) {
            commandValue = QuickActionDefinition.normalizeCommand(
                    commandBox.getValue()
            );
        }
    }

    private void save() {
        cacheFields();
        String name = displayName.strip();
        if (name.isBlank()) {
            fail(Component.literal("Enter a tooltip name for this button."));
            return;
        }
        if (!manager.isRegisteredItem(iconItemId)) {
            fail(Component.literal("Choose a valid item icon."));
            return;
        }

        QuickActionDefinition definition;
        if (actionType == QuickActionType.COMMAND) {
            String command = QuickActionDefinition.normalizeCommand(commandValue);
            if (command.isBlank()) {
                fail(Component.literal("Enter a command, such as /home."));
                return;
            }
            definition = QuickActionDefinition.command(name, iconItemId, command);
        } else {
            if (keybindValue.isBlank()
                    || manager.findKeyMapping(keybindValue) == null) {
                fail(Component.literal("Choose a registered Minecraft keybind."));
                return;
            }
            definition = QuickActionDefinition.keybind(
                    name,
                    iconItemId,
                    keybindValue
            );
        }

        manager.setAction(slotIndex, definition);
        closeEditor();
    }

    private void clear() {
        manager.clearAction(slotIndex);
        closeEditor();
    }

    private void fail(Component message) {
        statusMessage = message;
        updateSaveState();
    }

    private void updateSaveState() {
        if (saveButton == null) {
            return;
        }
        saveButton.active = actionType == QuickActionType.COMMAND
                ? commandBox != null
                : !keybindValue.isBlank();
    }

    private Component typeLabel() {
        return Component.literal(
                "Action Type: " + (actionType == QuickActionType.COMMAND
                        ? "Command"
                        : "Keybind")
        );
    }

    private Component keybindLabel() {
        if (keybindValue.isBlank()) {
            return Component.literal("Choose a Keybind...");
        }
        return manager.getAvailableKeyMappings().stream()
                .filter(option -> option.id().equals(keybindValue))
                .findFirst()
                .<Component>map(option -> Component.literal("Selected: ")
                        .append(option.displayName())
                        .append(" [")
                        .append(option.boundKey())
                        .append("]"))
                .orElse(Component.literal("Choose a Keybind..."));
    }

    private void refreshIconButtonTooltip() {
        if (iconButton == null) {
            return;
        }
        Identifier id = Identifier.tryParse(iconItemId);
        if (id == null) {
            iconButton.setTooltip(Tooltip.create(Component.literal("Choose an item icon")));
            return;
        }
        var item = BuiltInRegistries.ITEM.getOptional(id);
        iconButton.setTooltip(Tooltip.create(item
                .<Component>map(value -> value.getName(value.getDefaultInstance()).copy()
                        .append("\n")
                        .append(Component.literal(id.toString()).withColor(MUTED_COLOR)))
                .orElse(Component.literal("Choose an item icon"))));
    }

    void selectKeybind(String id) {
        keybindValue = id == null ? "" : id;
        actionType = QuickActionType.KEYBIND;
        statusMessage = null;
    }

    void selectIcon(String id) {
        if (id != null && manager.isRegisteredItem(id)) {
            iconItemId = id;
            statusMessage = null;
        }
    }

    @Override
    public void render(GuiGraphicsExtractor graphics, int mouseX, int mouseY, float partialTick) {
        graphics.fill(
                panelX,
                panelY,
                panelX + panelWidth,
                panelY + panelHeight,
                PANEL_COLOR
        );
        graphics.outline(panelX, panelY, panelWidth, panelHeight, PANEL_BORDER);
        graphics.centeredText(
                font,
                Component.literal("Quick Action " + (slotIndex + 1)),
                width / 2,
                panelY + 14,
                0xFFFFFFFF
        );

        int labelX = panelX + 20;
        int y = panelY + 42;
        graphics.text(font, Component.literal("Action Type"), labelX, y, LABEL_COLOR, false);
        y += 38;
        graphics.text(font, Component.literal("Tooltip Name"), labelX, y, LABEL_COLOR, false);
        y += 38;
        graphics.text(
                font,
                Component.literal(actionType == QuickActionType.COMMAND
                        ? "Command"
                        : "Keybind"),
                labelX,
                y,
                LABEL_COLOR,
                false
        );
        y += 38;
        graphics.text(font, Component.literal("Button Icon"), labelX, y, LABEL_COLOR, false);

        super.render(graphics, mouseX, mouseY, partialTick);
        renderChosenIcon(graphics);

        if (statusMessage != null) {
            graphics.centeredText(
                    font,
                    statusMessage,
                    width / 2,
                    panelY + panelHeight - 50,
                    ERROR_COLOR
            );
        } else {
            graphics.centeredText(
                    font,
                    Component.literal("Left-click a configured wrist button to run it; right-click to edit it."),
                    width / 2,
                    panelY + panelHeight - 50,
                    MUTED_COLOR
            );
        }
    }

    private void renderChosenIcon(GuiGraphicsExtractor graphics) {
        if (iconButton == null) {
            return;
        }
        Identifier id = Identifier.tryParse(iconItemId);
        if (id == null) {
            return;
        }
        var item = BuiltInRegistries.ITEM.getOptional(id);
        if (item.isEmpty()) {
            return;
        }
        ItemStack stack = item.get().getDefaultInstance();
        graphics.item(
                stack,
                iconButton.getX() + 3,
                iconButton.getY() + 2
        );
    }

    @Override
    public void tick() {
        updateSaveState();
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
