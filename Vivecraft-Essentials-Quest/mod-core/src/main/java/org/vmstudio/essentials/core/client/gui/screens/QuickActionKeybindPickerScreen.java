package org.vmstudio.essentials.core.client.gui.screens;

import net.minecraft.client.gui.GuiGraphicsExtractor;
import net.minecraft.client.gui.components.Button;
import net.minecraft.client.gui.components.EditBox;
import net.minecraft.client.gui.components.Tooltip;
import net.minecraft.client.gui.screens.Screen;
import net.minecraft.network.chat.Component;
import org.vmstudio.essentials.core.client.quickactions.QuickActionManager;
import org.vmstudio.visor.api.compatibility.mcversion.McScreen;

import java.util.ArrayList;
import java.util.List;
import java.util.Locale;

/** Searchable, VR-sized chooser for Minecraft's registered key mappings. */
final class QuickActionKeybindPickerScreen extends McScreen {
    private static final int PANEL_WIDTH = 520;
    private static final int PANEL_HEIGHT = 330;
    private static final int ROW_HEIGHT = 22;
    private static final int ROW_GAP = 2;

    private final QuickActionEditorScreen parent;
    private final QuickActionManager manager = QuickActionManager.getInstance();
    private final String initiallySelected;
    private final List<Button> rowButtons = new ArrayList<>();

    private List<QuickActionManager.KeybindOption> allOptions = List.of();
    private List<QuickActionManager.KeybindOption> filteredOptions = List.of();
    private String searchText = "";
    private int page;
    private int rowsPerPage;
    private int panelX;
    private int panelY;
    private int panelWidth;
    private int panelHeight;
    private Button previousButton;
    private Button nextButton;

    QuickActionKeybindPickerScreen(QuickActionEditorScreen parent,
                                   String initiallySelected) {
        super(Component.literal("Choose a Keybind"));
        this.parent = parent;
        this.initiallySelected = initiallySelected == null ? "" : initiallySelected;
    }

    @Override
    protected void init() {
        panelWidth = Math.min(PANEL_WIDTH, Math.max(280, width - 20));
        panelHeight = Math.min(PANEL_HEIGHT, Math.max(250, height - 20));
        panelX = (width - panelWidth) / 2;
        panelY = Math.max(5, (height - panelHeight) / 2);
        rowsPerPage = Math.max(4, Math.min(9, (panelHeight - 114) / (ROW_HEIGHT + ROW_GAP)));

        int contentX = panelX + 18;
        int contentWidth = panelWidth - 36;
        EditBox searchBox = new EditBox(
                font,
                contentX,
                panelY + 34,
                contentWidth,
                20,
                Component.literal("Search keybinds")
        );
        searchBox.setMaxLength(128);
        searchBox.setHint(Component.literal("Search action name, assigned key, or internal ID"));
        searchBox.setValue(searchText);
        searchBox.setResponder(value -> {
            searchText = value;
            page = 0;
            refreshFilter();
        });
        addRenderableWidget(searchBox);

        int rowY = panelY + 62;
        rowButtons.clear();
        for (int row = 0; row < rowsPerPage; row++) {
            final int rowIndex = row;
            Button button = addRenderableWidget(Button.builder(
                    Component.empty(),
                    ignored -> chooseRow(rowIndex)
            ).bounds(
                    contentX,
                    rowY + row * (ROW_HEIGHT + ROW_GAP),
                    contentWidth,
                    ROW_HEIGHT
            ).build());
            rowButtons.add(button);
        }

        int bottomY = panelY + panelHeight - 30;
        previousButton = addRenderableWidget(Button.builder(
                Component.literal("Previous"),
                ignored -> {
                    page--;
                    refreshRows();
                }
        ).bounds(contentX, bottomY, 90, 20).build());
        nextButton = addRenderableWidget(Button.builder(
                Component.literal("Next"),
                ignored -> {
                    page++;
                    refreshRows();
                }
        ).bounds(contentX + contentWidth - 90, bottomY, 90, 20).build());
        addRenderableWidget(Button.builder(
                Component.literal("Cancel"),
                ignored -> minecraft.gui.setScreen(parent)
        ).bounds(width / 2 - 45, bottomY, 90, 20).build());

        allOptions = manager.getAvailableKeyMappings();
        refreshFilter();
        setInitialFocus(searchBox);
    }

    private void refreshFilter() {
        String needle = searchText.strip().toLowerCase(Locale.ROOT);
        filteredOptions = allOptions.stream()
                .filter(option -> needle.isEmpty()
                        || option.displayName().getString().toLowerCase(Locale.ROOT).contains(needle)
                        || option.boundKey().getString().toLowerCase(Locale.ROOT).contains(needle)
                        || option.id().toLowerCase(Locale.ROOT).contains(needle))
                .toList();
        refreshRows();
    }

    private void refreshRows() {
        int pageCount = pageCount();
        page = Math.max(0, Math.min(page, pageCount - 1));
        int start = page * rowsPerPage;
        for (int row = 0; row < rowButtons.size(); row++) {
            Button button = rowButtons.get(row);
            int index = start + row;
            boolean present = index < filteredOptions.size();
            button.visible = present;
            button.active = present;
            if (!present) {
                button.setTooltip(null);
                continue;
            }

            QuickActionManager.KeybindOption option = filteredOptions.get(index);
            boolean selected = option.id().equals(initiallySelected);
            button.setMessage(Component.literal(selected ? "> " : "")
                    .append(option.displayName())
                    .append("  [")
                    .append(option.boundKey())
                    .append("]"));
            button.setTooltip(Tooltip.create(Component.literal(option.id())));
        }
        if (previousButton != null) {
            previousButton.active = page > 0;
        }
        if (nextButton != null) {
            nextButton.active = page + 1 < pageCount;
        }
    }

    private int pageCount() {
        return Math.max(1, (filteredOptions.size() + rowsPerPage - 1) / rowsPerPage);
    }

    private void chooseRow(int row) {
        int index = page * rowsPerPage + row;
        if (index < 0 || index >= filteredOptions.size()) {
            return;
        }
        parent.selectKeybind(filteredOptions.get(index).id());
        minecraft.gui.setScreen(parent);
    }

    @Override
    public void render(GuiGraphicsExtractor graphics, int mouseX, int mouseY, float partialTick) {
        graphics.fill(panelX, panelY, panelX + panelWidth, panelY + panelHeight, 0xE0181818);
        graphics.outline(panelX, panelY, panelWidth, panelHeight, 0xFF777777);
        graphics.centeredText(font, title, width / 2, panelY + 13, 0xFFFFFFFF);
        super.render(graphics, mouseX, mouseY, partialTick);

        Component count = filteredOptions.isEmpty()
                ? Component.literal("No matching keybinds")
                : Component.literal("Page " + (page + 1) + " / " + pageCount()
                        + "  -  " + filteredOptions.size() + " keybinds");
        graphics.centeredText(
                font,
                count,
                width / 2,
                panelY + panelHeight - 46,
                filteredOptions.isEmpty() ? 0xFFFF7777 : 0xFFAAAAAA
        );
    }

    @Override
    public void onClose() {
        minecraft.gui.setScreen(parent);
    }

    @Override
    public boolean isPauseScreen() {
        return true;
    }
}
