package org.vmstudio.essentials.core.client.gui.screens;

import net.minecraft.client.gui.GuiGraphicsExtractor;
import net.minecraft.client.gui.components.Button;
import net.minecraft.client.gui.components.EditBox;
import net.minecraft.client.gui.components.Tooltip;
import net.minecraft.client.gui.screens.Screen;
import net.minecraft.core.registries.BuiltInRegistries;
import net.minecraft.network.chat.Component;
import net.minecraft.resources.Identifier;
import net.minecraft.world.item.Item;
import net.minecraft.world.item.ItemStack;
import org.vmstudio.visor.api.compatibility.mcversion.McScreen;

import java.util.ArrayList;
import java.util.Comparator;
import java.util.List;
import java.util.Locale;

/** Searchable, paged picker containing every registered Minecraft item icon. */
final class QuickActionIconPickerScreen extends McScreen {
    private static final int PANEL_WIDTH = 540;
    private static final int PANEL_HEIGHT = 360;
    private static final int CELL_SIZE = 24;
    private static final int CELL_GAP = 3;

    private final QuickActionEditorScreen parent;
    private final String initiallySelected;
    private final List<Button> itemButtons = new ArrayList<>();

    private List<ItemEntry> allItems = List.of();
    private List<ItemEntry> filteredItems = List.of();
    private String searchText = "";
    private int page;
    private int columns;
    private int rows;
    private int gridX;
    private int gridY;
    private int panelX;
    private int panelY;
    private int panelWidth;
    private int panelHeight;
    private Button previousButton;
    private Button nextButton;

    QuickActionIconPickerScreen(QuickActionEditorScreen parent,
                                String initiallySelected) {
        super(Component.literal("Choose an Item Icon"));
        this.parent = parent;
        this.initiallySelected = initiallySelected == null ? "" : initiallySelected;
    }

    @Override
    protected void init() {
        panelWidth = Math.min(PANEL_WIDTH, Math.max(280, width - 20));
        panelHeight = Math.min(PANEL_HEIGHT, Math.max(260, height - 20));
        panelX = (width - panelWidth) / 2;
        panelY = Math.max(5, (height - panelHeight) / 2);

        int contentX = panelX + 18;
        int contentWidth = panelWidth - 36;
        columns = Math.max(6, Math.min(12, (contentWidth + CELL_GAP) / (CELL_SIZE + CELL_GAP)));
        rows = Math.max(4, Math.min(8, (panelHeight - 128) / (CELL_SIZE + CELL_GAP)));
        int gridWidth = columns * CELL_SIZE + (columns - 1) * CELL_GAP;
        gridX = panelX + (panelWidth - gridWidth) / 2;
        gridY = panelY + 66;

        EditBox searchBox = new EditBox(
                font,
                contentX,
                panelY + 35,
                contentWidth,
                20,
                Component.literal("Search item icons")
        );
        searchBox.setMaxLength(128);
        searchBox.setHint(Component.literal("Search item name, mod ID, or item ID"));
        searchBox.setValue(searchText);
        searchBox.setResponder(value -> {
            searchText = value;
            page = 0;
            refreshFilter();
        });
        addRenderableWidget(searchBox);

        itemButtons.clear();
        for (int index = 0; index < pageSize(); index++) {
            final int cellIndex = index;
            int column = index % columns;
            int row = index / columns;
            Button button = addRenderableWidget(Button.builder(
                    Component.empty(),
                    ignored -> chooseCell(cellIndex)
            ).bounds(
                    gridX + column * (CELL_SIZE + CELL_GAP),
                    gridY + row * (CELL_SIZE + CELL_GAP),
                    CELL_SIZE,
                    CELL_SIZE
            ).build());
            itemButtons.add(button);
        }

        int bottomY = panelY + panelHeight - 30;
        previousButton = addRenderableWidget(Button.builder(
                Component.literal("Previous"),
                ignored -> {
                    page--;
                    refreshCells();
                }
        ).bounds(contentX, bottomY, 90, 20).build());
        nextButton = addRenderableWidget(Button.builder(
                Component.literal("Next"),
                ignored -> {
                    page++;
                    refreshCells();
                }
        ).bounds(contentX + contentWidth - 90, bottomY, 90, 20).build());
        addRenderableWidget(Button.builder(
                Component.literal("Cancel"),
                ignored -> minecraft.gui.setScreen(parent)
        ).bounds(width / 2 - 45, bottomY, 90, 20).build());

        allItems = BuiltInRegistries.ITEM.stream()
                .map(item -> new ItemEntry(BuiltInRegistries.ITEM.getKey(item), item))
                .filter(entry -> entry.id() != null
                        && !entry.id().getPath().equals("air"))
                .sorted(Comparator.comparing(
                        entry -> entry.id().toString(),
                        String.CASE_INSENSITIVE_ORDER
                ))
                .toList();
        refreshFilter();
        setInitialFocus(searchBox);
    }

    private int pageSize() {
        return columns * rows;
    }

    private void refreshFilter() {
        String needle = searchText.strip().toLowerCase(Locale.ROOT);
        filteredItems = allItems.stream()
                .filter(entry -> needle.isEmpty()
                        || entry.id().toString().toLowerCase(Locale.ROOT).contains(needle)
                        || entry.id().getNamespace().toLowerCase(Locale.ROOT).contains(needle)
                        || entry.item().getName(entry.item().getDefaultInstance()).getString()
                        .toLowerCase(Locale.ROOT).contains(needle))
                .toList();
        refreshCells();
    }

    private void refreshCells() {
        int pageCount = pageCount();
        page = Math.max(0, Math.min(page, pageCount - 1));
        int start = page * pageSize();
        for (int cell = 0; cell < itemButtons.size(); cell++) {
            Button button = itemButtons.get(cell);
            int index = start + cell;
            boolean present = index < filteredItems.size();
            button.visible = present;
            button.active = present;
            if (!present) {
                button.setTooltip(null);
                continue;
            }
            ItemEntry entry = filteredItems.get(index);
            button.setTooltip(Tooltip.create(
                    entry.item().getName(entry.item().getDefaultInstance()).copy()
                            .append("\n")
                            .append(Component.literal(entry.id().toString()).withColor(0xAAAAAA))
            ));
        }
        if (previousButton != null) {
            previousButton.active = page > 0;
        }
        if (nextButton != null) {
            nextButton.active = page + 1 < pageCount;
        }
    }

    private int pageCount() {
        return Math.max(1, (filteredItems.size() + pageSize() - 1) / pageSize());
    }

    private void chooseCell(int cell) {
        int index = page * pageSize() + cell;
        if (index < 0 || index >= filteredItems.size()) {
            return;
        }
        parent.selectIcon(filteredItems.get(index).id().toString());
        minecraft.gui.setScreen(parent);
    }

    @Override
    public void render(GuiGraphicsExtractor graphics, int mouseX, int mouseY, float partialTick) {
        graphics.fill(panelX, panelY, panelX + panelWidth, panelY + panelHeight, 0xE0181818);
        graphics.outline(panelX, panelY, panelWidth, panelHeight, 0xFF777777);
        graphics.centeredText(font, title, width / 2, panelY + 13, 0xFFFFFFFF);
        super.render(graphics, mouseX, mouseY, partialTick);
        renderItemIcons(graphics);

        Component count = filteredItems.isEmpty()
                ? Component.literal("No matching items")
                : Component.literal("Page " + (page + 1) + " / " + pageCount()
                        + "  -  " + filteredItems.size() + " items");
        graphics.centeredText(
                font,
                count,
                width / 2,
                panelY + panelHeight - 46,
                filteredItems.isEmpty() ? 0xFFFF7777 : 0xFFAAAAAA
        );
    }

    private void renderItemIcons(GuiGraphicsExtractor graphics) {
        int start = page * pageSize();
        for (int cell = 0; cell < itemButtons.size(); cell++) {
            int index = start + cell;
            if (index >= filteredItems.size()) {
                break;
            }
            Button button = itemButtons.get(cell);
            ItemEntry entry = filteredItems.get(index);
            ItemStack stack = entry.item().getDefaultInstance();
            graphics.item(
                    stack,
                    button.getX() + (CELL_SIZE - 16) / 2,
                    button.getY() + (CELL_SIZE - 16) / 2
            );
            if (entry.id().toString().equals(initiallySelected)) {
                graphics.outline(
                        button.getX(),
                        button.getY(),
                        button.getWidth(),
                        button.getHeight(),
                        0xFF7FD67F
                );
            }
        }
    }

    @Override
    public void onClose() {
        minecraft.gui.setScreen(parent);
    }

    @Override
    public boolean isPauseScreen() {
        return true;
    }

    private record ItemEntry(Identifier id, Item item) {
    }
}
