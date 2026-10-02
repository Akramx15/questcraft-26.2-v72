package org.questcraft.veq.client.gui;

import net.minecraft.ChatFormatting;
import net.minecraft.client.Minecraft;
import net.minecraft.client.gui.GuiGraphicsExtractor;
import net.minecraft.client.gui.screens.inventory.InventoryScreen;
import net.minecraft.client.input.MouseButtonEvent;
import net.minecraft.client.renderer.RenderPipelines;
import net.minecraft.client.resources.sounds.SimpleSoundInstance;
import net.minecraft.core.registries.BuiltInRegistries;
import net.minecraft.network.chat.Component;
import net.minecraft.network.protocol.game.ServerboundContainerClosePacket;
import net.minecraft.resources.Identifier;
import net.minecraft.sounds.SoundEvents;
import net.minecraft.world.entity.player.Inventory;
import net.minecraft.world.entity.player.Player;
import net.minecraft.world.inventory.ContainerInput;
import net.minecraft.world.inventory.CraftingContainer;
import net.minecraft.world.inventory.InventoryMenu;
import net.minecraft.world.inventory.ResultSlot;
import net.minecraft.world.inventory.Slot;
import net.minecraft.world.item.Item;
import net.minecraft.world.item.ItemStack;
import net.minecraft.world.item.Items;
import org.jetbrains.annotations.Nullable;
import org.questcraft.veq.VivecraftEssentialsQuest;
import org.questcraft.veq.client.config.VepFeatureConfig;
import org.questcraft.veq.client.config.VepFeatureConfig.StatusMetric;
import org.questcraft.veq.client.config.VepFeatureConfig.StatusPosition;
import org.questcraft.veq.client.compat.VepUtilityActionRegistry;
import org.questcraft.veq.client.quickactions.QuickActionDefinition;
import org.questcraft.veq.client.quickactions.QuickActionManager;
import org.questcraft.veq.client.overlay.VepScreenContent;
import org.questcraft.veq.client.overlay.VeqOwnedPointerCancellation;

import java.util.ArrayList;
import java.util.IdentityHashMap;
import java.util.List;
import java.util.Map;
import java.util.Optional;

/**
 * VEP's compact player inventory adapted to Minecraft 26.2. It is initialized,
 * rendered and driven by the wrist overlay without ever becoming
 * {@code Minecraft.gui.screen()}.
 */
public final class VepWristInventoryScreen
        extends VepVrInventoryEffectScreen<InventoryMenu>
        implements EmbeddedSlotLayout, VepScreenContent, VeqOwnedPointerCancellation {
    public static final int PANEL_WIDTH = VepInventoryLayout.PANEL_WIDTH;
    public static final int PANEL_HEIGHT = VepInventoryLayout.PANEL_HEIGHT;

    private static final int QUICK_ACTION_SIZE = VepInventoryLayout.QUICK_ACTION_SIZE;
    private static final int STATUS_STRIP_X = 42;
    private static final int STATUS_STRIP_WIDTH = 174;
    private static final int STATUS_CELL_WIDTH = STATUS_STRIP_WIDTH / 2;
    private static final int STATUS_CELL_HEIGHT = 16;
    private static final int UTILITY_ACTION_SIZE = 20;
    private static final int UTILITY_ACTION_GAP = 2;
    private static final Identifier PANEL_TEXTURE = Identifier.fromNamespaceAndPath(
            "visor_essentials",
            "textures/gui/inventory.png"
    );
    private static final Identifier HEALTH_ICON = Identifier.withDefaultNamespace("hud/heart/full");
    private static final Identifier HEALTH_EMPTY_ICON = Identifier.withDefaultNamespace("hud/heart/container");
    private static final Identifier HEALTH_HALF_ICON = Identifier.withDefaultNamespace("hud/heart/half");
    private static final Identifier ABSORPTION_ICON = Identifier.withDefaultNamespace("hud/heart/absorbing_full");
    private static final Identifier HUNGER_ICON = Identifier.withDefaultNamespace("hud/food_full");
    private static final Identifier HUNGER_EMPTY_ICON = Identifier.withDefaultNamespace("hud/food_empty");
    private static final Identifier HUNGER_HALF_ICON = Identifier.withDefaultNamespace("hud/food_half");
    private static final Identifier ARMOR_ICON = Identifier.withDefaultNamespace("hud/armor_full");
    private static final Identifier ARMOR_EMPTY_ICON = Identifier.withDefaultNamespace("hud/armor_empty");
    private static final Identifier ARMOR_HALF_ICON = Identifier.withDefaultNamespace("hud/armor_half");
    private static final Identifier EXPERIENCE_BACKGROUND =
            Identifier.withDefaultNamespace("hud/experience_bar_background");
    private static final Identifier EXPERIENCE_PROGRESS =
            Identifier.withDefaultNamespace("hud/experience_bar_progress");

    private final Map<Slot, SlotPosition> positions = new IdentityHashMap<>();
    private final Navigation navigation;
    private final QuickActionManager quickActions = QuickActionManager.getInstance();
    private final QuickActionDefinition[] cachedQuickActions = new QuickActionDefinition[12];
    private final ItemStack[] cachedQuickActionIcons = new ItemStack[12];
    private final VepScreenLayoutRevision layoutRevisionTracker =
            new VepScreenLayoutRevision();
    private float pointerX;
    private float pointerY;
    private int hoveredQuickAction = -1;
    private boolean quickActionPress;
    private boolean utilityActionPress;

    public VepWristInventoryScreen(Player player) {
        this(player, Navigation.NONE);
    }

    public VepWristInventoryScreen(Player player, Navigation navigation) {
        super(
                player.inventoryMenu,
                player.getInventory(),
                Component.translatable("vivecraft_essentials_quest.inventory"),
                PANEL_WIDTH,
                PANEL_HEIGHT
        );
        this.navigation = navigation == null ? Navigation.NONE : navigation;
        java.util.Arrays.fill(cachedQuickActionIcons, ItemStack.EMPTY);
    }

    @Override
    protected void init() {
        super.init();
        rebuildSlotLayout();
    }

    @Override
    protected void extractSlots(GuiGraphicsExtractor graphics, int mouseX, int mouseY) {
        for (Slot slot : menu.slots) {
            SlotPosition position = positions.get(slot);
            if (position != null && slot.isActive()) {
                extractSlot(graphics, slot, position.x(), position.y());
            }
        }
    }

    @Override
    protected void renderVepBackground(GuiGraphicsExtractor graphics,
                                       float partialTick,
                                       int mouseX,
                                       int mouseY) {
        // Preserve VEP's authored transparent gaps around its inventory
        // islands. The external renderer now invokes this background pass
        // explicitly, so a synthetic full-rectangle plate is no longer needed.
        graphics.blit(
                RenderPipelines.GUI_TEXTURED,
                PANEL_TEXTURE,
                leftPos,
                topPos,
                0.0F,
                0.0F,
                PANEL_WIDTH,
                PANEL_HEIGHT,
                PANEL_WIDTH,
                PANEL_HEIGHT
        );
        if (minecraft.player != null
                && VepFeatureConfig.getInstance().showPlayerPreview()) {
            InventoryScreen.extractEntityInInventoryFollowsMouse(
                    graphics,
                    leftPos + 26,
                    topPos + 8,
                    leftPos + 75,
                    topPos + 78,
                    30,
                    0.0625F,
                    pointerX,
                    pointerY,
                    minecraft.player
            );
        }
        // The original VEP texture omits offhand. Keep the slot in the same
        // compact panel and draw a native-looking frame without changing the
        // server-owned InventoryMenu slot identity.
        VepInventoryLayout.Position offhand = VepInventoryLayout.offhand();
        int offhandX = leftPos + offhand.x() - 1;
        int offhandY = topPos + offhand.y() - 1;
        graphics.fill(offhandX, offhandY, offhandX + 18, offhandY + 18, 0xFF373737);
        graphics.outline(offhandX, offhandY, 18, 18, 0xFF8B8B8B);
    }

    @Override
    protected void extractLabels(GuiGraphicsExtractor graphics, int mouseX, int mouseY) {
        // The compact texture intentionally has no desktop inventory labels.
    }

    @Override
    protected void renderVepContent(GuiGraphicsExtractor graphics,
                                    int mouseX,
                                    int mouseY,
                                    float partialTick) {
        // Preserve the original VEP order: vanilla container/slots and
        // potion effects first, feature decorations second, then tooltips in
        // a dedicated pass.  The old adapter painted the panel here before
        // calling super, which did not match VRInvScreen at all.
        super.renderVepContent(graphics, mouseX, mouseY, partialTick);
        pointerX = mouseX;
        pointerY = mouseY;
        hoveredQuickAction = findQuickAction(mouseX, mouseY);
        renderQuickActions(graphics, mouseX, mouseY, false);
        renderUtilityActions(graphics, mouseX, mouseY, false);
        renderStatusHud(graphics, mouseX, mouseY, false);
        renderVepTooltip(graphics, mouseX, mouseY);
        renderStatusHud(graphics, mouseX, mouseY, true);
        renderQuickActions(graphics, mouseX, mouseY, true);
        renderUtilityActions(graphics, mouseX, mouseY, true);
        // The owning wrist surface adds its pointer and Minecraft's carried
        // item in a final ordered pass. Keeping both out of screen-local
        // rendering prevents duplicate coplanar quads in VR.
    }

    @Override
    public boolean mouseClicked(MouseButtonEvent event, boolean doubleClick) {
        int quickAction = findQuickAction(event.x(), event.y());
        if ((event.button() == 0 || event.button() == 1) && quickAction >= 0) {
            quickActionPress = true;
            QuickActionDefinition definition = quickActions.getAction(quickAction);
            boolean edit = event.button() == 1
                    || Minecraft.getInstance().hasShiftDown()
                    || !definition.isConfigured();
            if (event.button() == 0 && definition.isConfigured() && !edit) {
                quickActions.execute(definition);
                minecraft.getSoundManager().play(
                        SimpleSoundInstance.forUI(SoundEvents.UI_BUTTON_CLICK, 1.0F)
                );
            } else {
                navigation.editQuickAction(quickAction, this);
            }
            return true;
        }
        int utilityAction = findUtilityAction(event.x(), event.y());
        if (event.button() == 0 && utilityAction >= 0) {
            List<VepUtilityActionRegistry.UtilityAction> visible =
                    VepUtilityActionRegistry.getInstance().visibleActions();
            if (utilityAction < visible.size()) {
                utilityActionPress = true;
                visible.get(utilityAction).action().run();
                minecraft.getSoundManager().play(
                        SimpleSoundInstance.forUI(SoundEvents.UI_BUTTON_CLICK, 1.0F)
                );
                return true;
            }
        }
        Bounds interaction = contentBounds();
        if (VepExtendedContainerInput.isExtendedArea(
                event.x(),
                event.y(),
                leftPos,
                topPos,
                PANEL_WIDTH,
                PANEL_HEIGHT,
                interaction.x(),
                interaction.y(),
                interaction.width(),
                interaction.height()
        )) {
            // Status/effects and every other VEP extension are not slots.
            // Consume the press before vanilla can convert it to -999/THROW.
            return true;
        }
        return super.mouseClicked(event, doubleClick);
    }

    @Override
    public boolean mouseReleased(MouseButtonEvent event) {
        if (quickActionPress) {
            quickActionPress = false;
            return true;
        }
        if (utilityActionPress) {
            utilityActionPress = false;
            return true;
        }
        return super.mouseReleased(event);
    }

    @Override
    protected boolean hasClickedOutside(double mouseX,
                                        double mouseY,
                                        int guiLeft,
                                        int guiTop) {
        Bounds interaction = contentBounds();
        return VepExtendedContainerInput.isOutside(
                mouseX,
                mouseY,
                interaction.x(),
                interaction.y(),
                interaction.width(),
                interaction.height()
        );
    }

    @Override
    public void veq$cancelOwnedPointerGesture() {
        quickActionPress = false;
        utilityActionPress = false;
    }

    @Override
    public boolean showsActiveEffects() {
        return VepFeatureConfig.getInstance().showPotionEffects();
    }

    @Override
    protected boolean veq$showPotionEffects() {
        return showsActiveEffects();
    }

    @Override
    public boolean isPauseScreen() {
        return false;
    }

    @Override
    public boolean isInGameUi() {
        return true;
    }

    /**
     * Closes the embedded inventory through Minecraft's normal container
     * protocol without changing the active GUI screen. The server returns any
     * carried stack and the 2x2 crafting inputs before the overlay disappears.
     */
    public void closeEmbedded() {
        if (minecraft.player == null || minecraft.player.connection == null) {
            return;
        }
        if (minecraft.player.inventoryMenu != menu || minecraft.player.containerMenu != menu) {
            VivecraftEssentialsQuest.LOGGER.warn(
                    "Discarding an embedded wrist screen after its InventoryMenu stopped being active; " +
                            "the server-owned container transition will reconcile cursor state"
            );
            return;
        }

        boolean reconciled = reconcileCarried();
        minecraft.player.connection.send(new ServerboundContainerClosePacket(menu.containerId));
        if (!reconciled) {
            // The close packet is the authoritative fallback: on the server,
            // AbstractContainerMenu.removed returns the cursor stack to the
            // inventory and drops only overflow. Do not clear it client-side.
            VivecraftEssentialsQuest.LOGGER.warn(
                    "Wrist carried stack awaits authoritative container-close reconciliation"
            );
        }
        removed();
    }

    /**
     * Returns the carried stack through ordinary container clicks before a
     * hard close. Matching stacks are filled first, then empty player slots.
     * No ItemStack is inserted, deleted or copied directly by the client.
     */
    private boolean reconcileCarried() {
        if (menu.getCarried().isEmpty()) {
            return true;
        }
        if (minecraft.gameMode == null || minecraft.player == null ||
                minecraft.player.containerMenu != menu) {
            return false;
        }

        for (int pass = 0; pass < 2 && !menu.getCarried().isEmpty(); pass++) {
            for (Slot slot : menu.slots) {
                ItemStack carried = menu.getCarried();
                if (carried.isEmpty()) {
                    break;
                }
                if (!(slot.container instanceof Inventory) || !slot.isActive() || !slot.mayPlace(carried)) {
                    continue;
                }
                ItemStack inSlot = slot.getItem();
                boolean matchingRoom = !inSlot.isEmpty()
                        && ItemStack.isSameItemSameComponents(inSlot, carried)
                        && inSlot.getCount() < Math.min(inSlot.getMaxStackSize(), slot.getMaxStackSize(carried));
                boolean empty = inSlot.isEmpty();
                if (pass == 0 ? !matchingRoom : !empty) {
                    continue;
                }
                minecraft.gameMode.handleContainerInput(
                        menu.containerId,
                        slot.index,
                        0,
                        ContainerInput.PICKUP,
                        minecraft.player
                );
            }
        }

        if (!menu.getCarried().isEmpty()) {
            // Vanilla's outside click is an authoritative drop and is used
            // only when every player-inventory slot rejected the remainder.
            minecraft.gameMode.handleContainerInput(
                    menu.containerId,
                    -999,
                    0,
                    ContainerInput.PICKUP,
                    minecraft.player
            );
        }
        return menu.getCarried().isEmpty();
    }

    @Override
    protected void containerTick() {
        // InventoryMenu is already the player's live menu; no desktop recipe-book tick.
    }

    @Override
    public @Nullable SlotPosition veq$slotPosition(Slot slot) {
        return positions.get(slot);
    }

    @Override
    public boolean veq$isOverSlot(Slot slot, double mouseX, double mouseY) {
        SlotPosition position = positions.get(slot);
        return position != null && contains(
                leftPos + position.x() - 1,
                topPos + position.y() - 1,
                18,
                18,
                mouseX,
                mouseY
        );
    }

    public boolean containsInteractionPoint(double x, double y) {
        if (x >= leftPos && x < leftPos + PANEL_WIDTH
                && y >= topPos && y < topPos + PANEL_HEIGHT) {
            return true;
        }
        EffectBounds effectBounds = veq$effectBounds();
        return (effectBounds != null && contains(
                effectBounds.x(), effectBounds.y(), effectBounds.width(), effectBounds.height(), x, y))
                || findQuickAction(x, y) >= 0
                || findUtilityAction(x, y) >= 0
                || isOverStatusHud(x, y);
    }

    public int hoveredQuickAction() {
        return hoveredQuickAction;
    }

    /** Stable key used only for transition haptics; it never escapes the UI. */
    public int hoverKey(double x, double y) {
        int quickAction = findQuickAction(x, y);
        if (quickAction >= 0) {
            return 10_000 + quickAction;
        }
        int utilityAction = findUtilityAction(x, y);
        if (utilityAction >= 0) {
            return 20_000 + utilityAction;
        }
        for (Map.Entry<Slot, SlotPosition> entry : positions.entrySet()) {
            SlotPosition position = entry.getValue();
            if (contains(
                    leftPos + position.x() - 1,
                    topPos + position.y() - 1,
                    18,
                    18,
                    x,
                    y
            )) {
                return entry.getKey().index;
            }
        }
        return -1;
    }

    private void rebuildSlotLayout() {
        positions.clear();
        for (Slot slot : menu.slots) {
            SlotPosition position = positionFor(slot);
            if (position != null) {
                positions.put(slot, position);
            }
        }
    }

    private @Nullable SlotPosition positionFor(Slot slot) {
        int x;
        int y;
        if (slot.container instanceof CraftingContainer) {
            int index = slot.getContainerSlot();
            VepInventoryLayout.Position position = VepInventoryLayout.crafting(index);
            x = position.x();
            y = position.y();
        } else if (slot.container instanceof Inventory) {
            int index = slot.getContainerSlot();
            if (index <= 8) {
                VepInventoryLayout.Position position = VepInventoryLayout.hotbar(index);
                x = position.x();
                y = position.y();
            } else if (index <= 35) {
                VepInventoryLayout.Position position = VepInventoryLayout.inventory(index);
                x = position.x();
                y = position.y();
            } else if (index <= 39) {
                VepInventoryLayout.Position position = VepInventoryLayout.armor(index);
                x = position.x();
                y = position.y();
            } else if (index == 40) {
                VepInventoryLayout.Position position = VepInventoryLayout.offhand();
                x = position.x();
                y = position.y();
            } else {
                return null;
            }
        } else if (slot instanceof ResultSlot) {
            VepInventoryLayout.Position position = VepInventoryLayout.result();
            x = position.x();
            y = position.y();
        } else {
            return null;
        }
        return new SlotPosition(x, y);
    }

    private void renderQuickActions(GuiGraphicsExtractor graphics,
                                    int mouseX,
                                    int mouseY,
                                    boolean tooltipPass) {
        int count = VepFeatureConfig.getInstance().quickActionDisplayMode().visibleSlots();
        for (int slot = 0; slot < count; slot++) {
            int x = quickActionX(slot);
            int y = quickActionY(slot);
            boolean hovered = contains(x, y, QUICK_ACTION_SIZE, QUICK_ACTION_SIZE, mouseX, mouseY);
            QuickActionDefinition definition = quickActions.getAction(slot);
            if (tooltipPass) {
                if (hovered) {
                    Component editHint = definition.isConfigured()
                            ? Component.literal("Right-click or Shift-click to edit")
                            .withStyle(ChatFormatting.GRAY)
                            : Component.literal("Choose a keybind or command")
                            .withStyle(ChatFormatting.GRAY);
                    graphics.setTooltipForNextFrame(
                            font,
                            List.of(quickActions.getTooltip(slot), editHint),
                            Optional.empty(),
                            mouseX,
                            mouseY
                    );
                }
                continue;
            }
            int background = hovered ? 0xE04B4B4B : 0xE02B2B2B;
            int border = hovered ? 0xFFFFFFFF : 0xFF9A9A9A;
            graphics.fill(x, y, x + QUICK_ACTION_SIZE, y + QUICK_ACTION_SIZE, background);
            graphics.outline(x, y, QUICK_ACTION_SIZE, QUICK_ACTION_SIZE, border);

            ItemStack icon = quickActionIcon(slot, definition);
            if (!icon.isEmpty()) {
                graphics.item(icon, x + 2, y + 2);
            } else {
                graphics.centeredText(
                        font,
                        "+",
                        x + QUICK_ACTION_SIZE / 2,
                        y + 6,
                        0xFFFFFFFF
                );
            }
        }
    }

    private int findQuickAction(double mouseX, double mouseY) {
        int count = VepFeatureConfig.getInstance().quickActionDisplayMode().visibleSlots();
        for (int slot = 0; slot < count; slot++) {
            if (contains(
                    quickActionX(slot),
                    quickActionY(slot),
                    QUICK_ACTION_SIZE,
                    QUICK_ACTION_SIZE,
                    mouseX,
                    mouseY
            )) {
                return slot;
            }
        }
        return -1;
    }

    private int quickActionX(int slot) {
        return leftPos + VepInventoryLayout.quickAction(slot).x();
    }

    private int quickActionY(int slot) {
        return topPos + VepInventoryLayout.quickAction(slot).y();
    }

    private void renderUtilityActions(GuiGraphicsExtractor graphics,
                                      int mouseX,
                                      int mouseY,
                                      boolean tooltipPass) {
        List<VepUtilityActionRegistry.UtilityAction> visible =
                VepUtilityActionRegistry.getInstance().visibleActions();
        for (int index = 0; index < visible.size(); index++) {
            Bounds bounds = utilityActionBounds(index);
            VepUtilityActionRegistry.UtilityAction action = visible.get(index);
            boolean hovered = contains(
                    bounds.x(), bounds.y(), bounds.width(), bounds.height(), mouseX, mouseY);
            if (tooltipPass) {
                if (hovered) {
                    graphics.setTooltipForNextFrame(
                            font,
                            List.of(action.tooltip()),
                            Optional.empty(),
                            mouseX,
                            mouseY
                    );
                }
                continue;
            }
            boolean toggled = action.toggled().getAsBoolean();
            int background = toggled
                    ? (hovered ? 0xE04B6251 : 0xD02E4735)
                    : (hovered ? 0xE0434343 : 0xD0181818);
            int border = toggled
                    ? (hovered ? 0xFFFFFFFF : 0xFF7FD67F)
                    : (hovered ? 0xFFFFFFFF : 0xFF9A9A9A);
            graphics.fill(
                    bounds.x(), bounds.y(),
                    bounds.x() + bounds.width(), bounds.y() + bounds.height(),
                    background
            );
            graphics.outline(
                    bounds.x(), bounds.y(), bounds.width(), bounds.height(),
                    border
            );
            if (!action.icon().isEmpty()) {
                graphics.item(action.icon(), bounds.x() + 2, bounds.y() + 2);
            }
        }
    }

    private int findUtilityAction(double mouseX, double mouseY) {
        List<VepUtilityActionRegistry.UtilityAction> visible =
                VepUtilityActionRegistry.getInstance().visibleActions();
        for (int index = 0; index < visible.size(); index++) {
            Bounds bounds = utilityActionBounds(index);
            if (contains(
                    bounds.x(), bounds.y(), bounds.width(), bounds.height(), mouseX, mouseY)) {
                return index;
            }
        }
        return -1;
    }

    private Bounds utilityActionBounds(int index) {
        int x = leftPos + 58;
        int y = topPos + 4 + index * (UTILITY_ACTION_SIZE + UTILITY_ACTION_GAP);
        return new Bounds(x, y, UTILITY_ACTION_SIZE, UTILITY_ACTION_SIZE);
    }

    @Override
    public VepWristInventoryScreen screen() {
        return this;
    }

    @Override
    public InventoryMenu menu() {
        return menu;
    }

    @Override
    public void hardClose() {
        closeEmbedded();
    }

    private void renderStatusHud(GuiGraphicsExtractor graphics,
                                 int mouseX,
                                 int mouseY,
                                 boolean tooltipPass) {
        VepFeatureConfig config = VepFeatureConfig.getInstance();
        if (!config.showStatusHud() || minecraft.player == null) {
            return;
        }
        StatusSnapshot status = StatusSnapshot.capture(minecraft.player);
        for (StatusPosition position : StatusPosition.values()) {
            List<StatusMetric> metrics = visibleMetrics(config, position);
            if (metrics.isEmpty()) {
                continue;
            }
            int columns = Math.min(2, metrics.size());
            int rows = (metrics.size() + 1) / 2;
            int width = columns * STATUS_CELL_WIDTH;
            int height = rows * STATUS_CELL_HEIGHT + 1;
            int startX = leftPos + STATUS_STRIP_X + (STATUS_STRIP_WIDTH - width) / 2;
            int startY = position == StatusPosition.BOTTOM
                    ? topPos + PANEL_HEIGHT - 1
                    : topPos - height + 1;
            if (!tooltipPass) {
                drawStatusBackground(graphics, startX, startY, width, height, columns, rows);
            }
            for (int index = 0; index < metrics.size(); index++) {
                int column = index % 2;
                int row = index / 2;
                if (columns == 2 && index == metrics.size() - 1 && metrics.size() % 2 != 0) {
                    column = 0;
                }
                int cellX = startX + column * STATUS_CELL_WIDTH;
                if (columns == 2 && index == metrics.size() - 1 && metrics.size() % 2 != 0) {
                    cellX += STATUS_CELL_WIDTH / 2;
                }
                Bounds cell = new Bounds(
                        cellX,
                        startY + 1 + row * STATUS_CELL_HEIGHT,
                        STATUS_CELL_WIDTH,
                        STATUS_CELL_HEIGHT
                );
                StatusMetric metric = metrics.get(index);
                if (!tooltipPass) {
                    drawStatusMetric(graphics, metric, status, cell);
                }
                if (tooltipPass && contains(
                        cell.x(), cell.y(), cell.width(), cell.height(), mouseX, mouseY)) {
                    graphics.setTooltipForNextFrame(
                            font,
                            statusTooltip(metric, status),
                            Optional.empty(),
                            mouseX,
                            mouseY
                    );
                }
            }
        }
    }

    private static List<StatusMetric> visibleMetrics(VepFeatureConfig config,
                                                     StatusPosition position) {
        List<StatusMetric> metrics = new ArrayList<>();
        for (StatusMetric metric : StatusMetric.values()) {
            if (config.statusVisible(metric) && config.statusPosition(metric) == position) {
                metrics.add(metric);
            }
        }
        return metrics;
    }

    private void drawStatusBackground(GuiGraphicsExtractor graphics,
                                      int x,
                                      int y,
                                      int width,
                                      int height,
                                      int columns,
                                      int rows) {
        graphics.fill(x, y, x + width, y + height, 0xEC171717);
        graphics.outline(x, y, width, height, 0xFF9A9A9A);
        if (columns > 1) {
            graphics.fill(
                    x + STATUS_CELL_WIDTH,
                    y + 1,
                    x + STATUS_CELL_WIDTH + 1,
                    y + height - 1,
                    0xFF505050
            );
        }
        for (int row = 1; row < rows; row++) {
            int separatorY = y + row * STATUS_CELL_HEIGHT;
            graphics.fill(x + 1, separatorY, x + width - 1, separatorY + 1, 0xFF505050);
        }
    }

    private void drawStatusMetric(GuiGraphicsExtractor graphics,
                                  StatusMetric metric,
                                  StatusSnapshot status,
                                  Bounds bounds) {
        if (metric == StatusMetric.EXPERIENCE) {
            graphics.centeredText(
                    font,
                    Integer.toString(status.experienceLevel()),
                    bounds.x() + bounds.width() / 2,
                    bounds.y() + 1,
                    0xFF80FF20
            );
            drawExperienceBar(
                    graphics,
                    bounds.x() + 3,
                    bounds.y() + 10,
                    81,
                    status.experienceProgress()
            );
            return;
        }
        int units = switch (metric) {
            case HEALTH -> Math.round(safeRatio(status.health(), status.maximumHealth()) * 20.0F);
            case HUNGER -> status.hunger();
            case ARMOR -> Math.min(status.armor(), 20);
            case EXPERIENCE -> 0;
        };
        Identifier empty = switch (metric) {
            case HEALTH -> HEALTH_EMPTY_ICON;
            case HUNGER -> HUNGER_EMPTY_ICON;
            case ARMOR -> ARMOR_EMPTY_ICON;
            case EXPERIENCE -> throw new IllegalArgumentException("Experience uses a bar");
        };
        Identifier half = switch (metric) {
            case HEALTH -> HEALTH_HALF_ICON;
            case HUNGER -> HUNGER_HALF_ICON;
            case ARMOR -> ARMOR_HALF_ICON;
            case EXPERIENCE -> throw new IllegalArgumentException("Experience uses a bar");
        };
        Identifier full = switch (metric) {
            case HEALTH -> HEALTH_ICON;
            case HUNGER -> HUNGER_ICON;
            case ARMOR -> ARMOR_ICON;
            case EXPERIENCE -> throw new IllegalArgumentException("Experience uses a bar");
        };
        int iconX = bounds.x() + 3;
        int iconY = bounds.y() + 2;
        for (int slot = 0; slot < 10; slot++) {
            drawHudSprite(graphics, empty, iconX, iconY, slot);
            int threshold = slot * 2;
            if (units >= threshold + 2) {
                drawHudSprite(graphics, full, iconX, iconY, slot);
            } else if (units == threshold + 1) {
                drawHudSprite(graphics, half, iconX, iconY, slot);
            }
        }
        if (metric == StatusMetric.HEALTH && status.absorption() > 0.0F) {
            int first = Math.min(9, Math.max(0, (units + 1) / 2));
            drawHudSprite(graphics, ABSORPTION_ICON, iconX, iconY, first);
        }
    }

    private static void drawHudSprite(GuiGraphicsExtractor graphics,
                                      Identifier sprite,
                                      int x,
                                      int y,
                                      int slot) {
        graphics.blitSprite(RenderPipelines.GUI_TEXTURED, sprite, x + slot * 8, y, 9, 9);
    }

    private static void drawExperienceBar(GuiGraphicsExtractor graphics,
                                          int x,
                                          int y,
                                          int width,
                                          float progress) {
        graphics.blitSprite(RenderPipelines.GUI_TEXTURED, EXPERIENCE_BACKGROUND, x, y, width, 5);
        int progressWidth = Math.round(Math.max(0.0F, Math.min(1.0F, progress)) * width);
        if (progressWidth > 0) {
            graphics.blitSprite(
                    RenderPipelines.GUI_TEXTURED,
                    EXPERIENCE_PROGRESS,
                    width,
                    5,
                    0,
                    0,
                    x,
                    y,
                    progressWidth,
                    5
            );
        }
    }

    private static List<Component> statusTooltip(StatusMetric metric, StatusSnapshot status) {
        return switch (metric) {
            case HEALTH -> status.absorption() > 0.0F
                    ? List.of(
                    Component.literal("Health: " + format(status.health()) + " / "
                            + format(status.maximumHealth())),
                    Component.literal("Absorption: +" + format(status.absorption()))
                            .withStyle(ChatFormatting.GOLD)
            )
                    : List.of(Component.literal("Health: " + format(status.health()) + " / "
                    + format(status.maximumHealth())));
            case HUNGER -> List.of(
                    Component.literal("Hunger: " + status.hunger() + " / 20"),
                    Component.literal("Saturation: " + format(status.saturation()))
                            .withStyle(ChatFormatting.GOLD)
            );
            case ARMOR -> List.of(Component.literal("Armor: " + status.armor()));
            case EXPERIENCE -> List.of(Component.literal(
                    "Experience: Level " + status.experienceLevel() + " ("
                            + Math.round(status.experienceProgress() * 100.0F) + "%)"
            ));
        };
    }

    private boolean isOverStatusHud(double x, double y) {
        VepFeatureConfig config = VepFeatureConfig.getInstance();
        if (!config.showStatusHud()) {
            return false;
        }
        for (StatusPosition position : StatusPosition.values()) {
            int height = statusHeight(position);
            if (height == 0) {
                continue;
            }
            int groupY = position == StatusPosition.BOTTOM
                    ? topPos + PANEL_HEIGHT - 1
                    : topPos - height + 1;
            if (contains(
                    leftPos + STATUS_STRIP_X,
                    groupY,
                    STATUS_STRIP_WIDTH,
                    height,
                    x,
                    y
            )) {
                return true;
            }
        }
        return false;
    }

    private int statusHeight(StatusPosition position) {
        List<StatusMetric> metrics = visibleMetrics(VepFeatureConfig.getInstance(), position);
        return metrics.isEmpty() ? 0 : ((metrics.size() + 1) / 2) * STATUS_CELL_HEIGHT + 1;
    }

    private static float safeRatio(float value, float maximum) {
        if (!Float.isFinite(value) || !Float.isFinite(maximum) || maximum <= 0.0F) {
            return 0.0F;
        }
        return Math.max(0.0F, Math.min(1.0F, value / maximum));
    }

    private static String format(float value) {
        if (Math.abs(value - Math.round(value)) < 0.01F) {
            return Integer.toString(Math.round(value));
        }
        return String.format(java.util.Locale.ROOT, "%.1f", value);
    }

    private static boolean contains(int x,
                                    int y,
                                    int width,
                                    int height,
                                    double mouseX,
                                    double mouseY) {
        return mouseX >= x && mouseX < x + width
                && mouseY >= y && mouseY < y + height;
    }

    private static ItemStack resolveIcon(String itemId) {
        Identifier identifier = itemId == null ? null : Identifier.tryParse(itemId);
        if (identifier == null) {
            return ItemStack.EMPTY;
        }
        Item item = BuiltInRegistries.ITEM.getValue(identifier);
        return item == null || item == Items.AIR ? ItemStack.EMPTY : new ItemStack(item);
    }

    private ItemStack quickActionIcon(int slot, QuickActionDefinition definition) {
        if (!definition.equals(cachedQuickActions[slot])) {
            cachedQuickActions[slot] = definition;
            cachedQuickActionIcons[slot] = resolveIcon(definition.iconItemId());
        }
        return cachedQuickActionIcons[slot];
    }

    public record Bounds(int x, int y, int width, int height) {
        public Bounds {
            if (width < 0 || height < 0) {
                throw new IllegalArgumentException("Negative bounds");
            }
        }

        public Bounds union(Bounds other) {
            int minX = Math.min(x, other.x);
            int minY = Math.min(y, other.y);
            int maxX = Math.max(x + width, other.x + other.width);
            int maxY = Math.max(y + height, other.y + other.height);
            return new Bounds(minX, minY, maxX - minX, maxY - minY);
        }
    }

    /** Exact content bounds used by the multi-surface adapter. */
    public Bounds contentBounds() {
        Bounds bounds = new Bounds(leftPos, topPos, PANEL_WIDTH, PANEL_HEIGHT);
        for (int slot = 0;
             slot < VepFeatureConfig.getInstance().quickActionDisplayMode().visibleSlots();
             slot++) {
            bounds = bounds.union(new Bounds(
                    quickActionX(slot),
                    quickActionY(slot),
                    QUICK_ACTION_SIZE,
                    QUICK_ACTION_SIZE
            ));
        }
        for (StatusPosition position : StatusPosition.values()) {
            int height = statusHeight(position);
            if (height <= 0) {
                continue;
            }
            int y = position == StatusPosition.BOTTOM
                    ? topPos + PANEL_HEIGHT - 1
                    : topPos - height + 1;
            bounds = bounds.union(new Bounds(
                    leftPos + STATUS_STRIP_X,
                    y,
                    STATUS_STRIP_WIDTH,
                    height
            ));
        }
        int utilityCount = VepUtilityActionRegistry.getInstance().visibleActions().size();
        for (int index = 0; index < utilityCount; index++) {
            bounds = bounds.union(utilityActionBounds(index));
        }
        EffectBounds effectBounds = veq$effectBounds();
        if (effectBounds != null) {
            bounds = bounds.union(new Bounds(
                    effectBounds.x(),
                    effectBounds.y(),
                    effectBounds.width(),
                    effectBounds.height()
            ));
        }
        return bounds;
    }

    @Override
    public Bounds visualBounds() {
        return VepSurfaceBackdrop.visualBounds(contentBounds(), width, height);
    }

    @Override
    public long visualLayoutRevision() {
        VepFeatureConfig config = VepFeatureConfig.getInstance();
        return layoutRevisionTracker.update(
                leftPos,
                topPos,
                width,
                height,
                config.revision(),
                veq$visibleEffectCount(),
                VepUtilityActionRegistry.getInstance().visibleLayoutRevision(),
                config.quickActionDisplayMode().visibleSlots()
        );
    }

    private record StatusSnapshot(float maximumHealth,
                                  float health,
                                  float absorption,
                                  int hunger,
                                  float saturation,
                                  int armor,
                                  int experienceLevel,
                                  float experienceProgress) {
        private static StatusSnapshot capture(Player player) {
            float maximumHealth = finiteNonNegative(player.getMaxHealth());
            float health = Math.min(finiteNonNegative(player.getHealth()), maximumHealth);
            return new StatusSnapshot(
                    maximumHealth,
                    health,
                    finiteNonNegative(player.getAbsorptionAmount()),
                    Math.max(0, Math.min(20, player.getFoodData().getFoodLevel())),
                    Math.max(0.0F, Math.min(20.0F,
                            finiteNonNegative(player.getFoodData().getSaturationLevel()))),
                    Math.max(0, player.getArmorValue()),
                    Math.max(0, player.experienceLevel),
                    Math.max(0.0F, Math.min(1.0F, player.experienceProgress))
            );
        }

        private static float finiteNonNegative(float value) {
            return Float.isFinite(value) ? Math.max(0.0F, value) : 0.0F;
        }
    }

    /**
     * UI-only navigation seam. The Vivecraft overlay adapter decides which
     * registered surface becomes visible; the inventory screen never calls
     * {@code Minecraft.setScreen()} for wrist/creative/container surfaces.
     */
    public interface Navigation {
        Navigation NONE = new Navigation() {
        };

        default void openCreative(VepWristInventoryScreen inventory) {
        }

        default void editQuickAction(int slot, VepWristInventoryScreen inventory) {
            QuickActionEditorScreen.open(slot, null);
        }

        default void openContextualContainer(VepWristInventoryScreen inventory) {
        }
    }
}
