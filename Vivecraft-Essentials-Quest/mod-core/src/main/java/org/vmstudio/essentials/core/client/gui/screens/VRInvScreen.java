package org.vmstudio.essentials.core.client.gui.screens;

import net.minecraft.ChatFormatting;
import org.vmstudio.essentials.core.client.compat.ColorfulHeartsCompat;
import org.vmstudio.essentials.core.client.compat.OverloadedArmorBarCompat;
import org.vmstudio.visor.api.VisorAPI;
import org.vmstudio.essentials.core.client.config.QuickActionDisplayMode;
import org.vmstudio.essentials.core.client.config.WristHudMetric;
import org.vmstudio.essentials.core.client.config.WristHudPosition;
import org.vmstudio.essentials.core.client.config.WristUiConfig;
import org.vmstudio.essentials.core.client.gui.ContainerSlot;
import org.vmstudio.essentials.core.client.gui.overlays.VROverlayContainer;
import org.vmstudio.essentials.core.client.extensions.AbstractContainerScreenExtension;
import org.vmstudio.essentials.core.client.quickactions.QuickActionDefinition;
import org.vmstudio.essentials.core.client.quickactions.QuickActionManager;
import org.vmstudio.essentials.core.common.VisorEssentials;
import net.minecraft.client.Minecraft;
import net.minecraft.client.gui.GuiGraphicsExtractor;
import net.minecraft.client.gui.components.AbstractWidget;
import net.minecraft.client.renderer.RenderPipelines;
import net.minecraft.client.gui.screens.Screen;
import net.minecraft.client.gui.screens.inventory.InventoryScreen;
import net.minecraft.client.resources.sounds.SimpleSoundInstance;
import net.minecraft.network.chat.Component;
import net.minecraft.resources.Identifier;
import net.minecraft.sounds.SoundEvents;
import net.minecraft.world.entity.player.Inventory;
import net.minecraft.world.inventory.*;
import net.minecraft.world.item.ItemStack;
import org.jetbrains.annotations.NotNull;
import org.jetbrains.annotations.Nullable;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.Optional;
import java.util.function.BooleanSupplier;
import java.util.function.Predicate;


public class VRInvScreen extends VRInvEffectInvScreen implements AbstractContainerScreenExtension {
    private static final int CRAFT_RESULT_X = 237;
    private static final int CRAFT_RESULT_Y = 36;
    private static final int CONTEXT_ACTION_WIDTH = 128;
    private static final int CONTEXT_ACTION_HEIGHT = 20;
    private static final int CONTEXT_ACTION_GAP = 6;
    private static final int UTILITY_ACTION_SIZE = 20;
    private static final int UTILITY_ACTION_GAP = 2;
    private static final int QUICK_ACTION_SIZE = 20;
    private static final int QUICK_ACTION_GAP = 2;
    private static final int QUICK_ACTION_FIRST_Y = 90;
    private static final int QUICK_ACTION_LEFT_X = 20;
    private static final int QUICK_ACTION_RIGHT_X = 218;
    private static final int QUICK_ACTION_OUTER_LEFT_X = -2;
    private static final int QUICK_ACTION_OUTER_RIGHT_X = 240;
    private static final int CREATIVE_MODE_ACTION_WIDTH = 128;
    private static final int CREATIVE_MODE_ACTION_HEIGHT = 20;
    private static final int CREATIVE_MODE_ACTION_GAP = 6;
    private static final int STATUS_STRIP_X = 42;
    private static final int STATUS_STRIP_WIDTH = 174;
    private static final int STATUS_METRIC_WIDTH = STATUS_STRIP_WIDTH / 2;
    private static final int STATUS_METRIC_HEIGHT = 16;

    private static final Identifier HEALTH_ICON = Identifier.fromNamespaceAndPath(
            "minecraft", "hud/heart/full"
    );
    private static final Identifier HEALTH_CONTAINER_ICON = Identifier.fromNamespaceAndPath(
            "minecraft", "hud/heart/container"
    );
    private static final Identifier HEALTH_HALF_ICON = Identifier.fromNamespaceAndPath(
            "minecraft", "hud/heart/half"
    );
    private static final Identifier ABSORPTION_FULL_ICON = Identifier.fromNamespaceAndPath(
            "minecraft", "hud/heart/absorbing_full"
    );
    private static final Identifier ABSORPTION_HALF_ICON = Identifier.fromNamespaceAndPath(
            "minecraft", "hud/heart/absorbing_half"
    );
    private static final Identifier HUNGER_ICON = Identifier.fromNamespaceAndPath(
            "minecraft", "hud/food_full"
    );
    private static final Identifier HUNGER_EMPTY_ICON = Identifier.fromNamespaceAndPath(
            "minecraft", "hud/food_empty"
    );
    private static final Identifier HUNGER_HALF_ICON = Identifier.fromNamespaceAndPath(
            "minecraft", "hud/food_half"
    );
    private static final Identifier ARMOR_ICON = Identifier.fromNamespaceAndPath(
            "minecraft", "hud/armor_full"
    );
    private static final Identifier ARMOR_EMPTY_ICON = Identifier.fromNamespaceAndPath(
            "minecraft", "hud/armor_empty"
    );
    private static final Identifier ARMOR_HALF_ICON = Identifier.fromNamespaceAndPath(
            "minecraft", "hud/armor_half"
    );
    private static final Identifier EXPERIENCE_BACKGROUND = Identifier.fromNamespaceAndPath(
            "minecraft", "hud/experience_bar_background"
    );
    private static final Identifier EXPERIENCE_PROGRESS = Identifier.fromNamespaceAndPath(
            "minecraft", "hud/experience_bar_progress"
    );

    private static final Identifier IMAGE_FULL = Identifier.fromNamespaceAndPath(
            VisorEssentials.MOD_ID,"textures/gui/inventory.png"
    );
    private static final Identifier IMAGE_SIMPLIFIED = Identifier.fromNamespaceAndPath(
            VisorEssentials.MOD_ID,"textures/gui/inventory_simplified.png"
    );
    private static final Component CREATIVE_MODE_ACTION_LABEL = Component.translatable(
            "visor_essentials.inventory.creative_mode"
    );
    private static final Component CREATIVE_MODE_ACTION_TOOLTIP = Component.translatable(
            "visor_essentials.inventory.creative_mode.tooltip"
    );


    private float xMouse;
    private float yMouse;

    private @Nullable Component contextActionLabel;
    private @Nullable Runnable contextAction;
    private @Nullable Runnable creativeModeAction;
    private final Map<String, UtilityAction> utilityActions = new LinkedHashMap<>();
    private final VisibleActionCache<UtilityAction> visibleUtilityActionCache =
            new VisibleActionCache<>();
    // Definitions are immutable. Keep their display-only stacks until a slot's
    // definition changes instead of allocating up to twelve stacks per frame.
    private final IndexedValueCache<QuickActionDefinition, ItemStack> quickActionIconCache =
            new IndexedValueCache<>(QuickActionManager.SLOT_COUNT);
    // Render methods consume these primitives synchronously, so one screen-owned
    // snapshot can safely serve every frame without escaping to queued render state.
    private final StatusSnapshot statusSnapshot = new StatusSnapshot();
    private final LayoutCacheState layoutCacheState = new LayoutCacheState();
    private @Nullable StatusLayout cachedStatusLayout;
    private @Nullable InventoryBounds cachedCombinedBounds;

    public VRInvScreen(AbstractContainerMenu menu,
                       Inventory inventory) {
        super(menu,  inventory, Component.literal(""));
        this.titleLabelX = 97;
        visorEssentials$setVRContainer(true);
    }

    /**
     * Returns the slot resolved by Minecraft's normal container hover path.
     * The overlay performs all safety checks before dispatching an input.
     */
    public @Nullable Slot getHoveredSlotForQuickActions() {
        return hoveredSlot;
    }
    @Override
    public void visorEssentials$fillVRSlots(
            @NotNull List<ContainerSlot> slots
    ) {
        fullInventory = !VisorAPI.client().getGuiManager()
                .getOverlayManager().getOverlay(VROverlayContainer.ID).isEnabled();

        slots.clear();
        for(Slot slot : menu.slots){
            int posX = 0;
            int posY = 0;
            if((slot.container instanceof CraftingContainer)
                    && fullInventory){
                // 2x2 grid layout
                int index = slot.getContainerSlot();
                int row = index / 2;
                int col = index % 2;
                posX = 181 + col * 18;
                posY = 26 + row * 18;
                slots.add(new ContainerSlot(slot, posX,posY));
            }else if(slot.container instanceof Inventory){
                if(slot.getContainerSlot()<=8){
                    //hotbar
                    switch (slot.getContainerSlot()){
                        case 0 -> {
                            posX = 121;
                            posY = 38;
                        }
                        case 1 -> {
                            posX = 121;
                            posY = 11;
                        }
                        case 2 -> {
                            posX = 148;
                            posY = 11;
                        }
                        case 3 -> {
                            posX = 148;
                            posY = 38;
                        }
                        case 4 -> {
                            posX = 148;
                            posY = 65;
                        }
                        case 5 -> {
                            posX = 121;
                            posY = 65;
                        }
                        case 6 -> {
                            posX = 94;
                            posY = 65;
                        }
                        case 7 -> {
                            posX = 94;
                            posY = 38;
                        }
                        case 8 -> {
                            posX = 94;
                            posY = 11;
                        }
                    }

                }else if(slot.getContainerSlot()<=35) {
                    // 9x3 grid layout
                    int index = slot.getContainerSlot() - 9;
                    int row = index / 9;
                    int col = index % 9;
                    posX = 49 + col * 18;
                    posY = 96 + row * 18;
                }else{
                    if(!fullInventory) continue;
                    // equipment slots
                    if(slot.getContainerSlot() == 40) continue; //ignore offhand
                    int index = slot.getContainerSlot() - 36;
                    posX = 8;
                    posY = 62 + index * -18;
                }
                slots.add(new ContainerSlot(slot,posX,posY));
            }
            else if(fullInventory && slot instanceof ResultSlot){
                posX = CRAFT_RESULT_X;
                posY = CRAFT_RESULT_Y;
                slots.add(new ContainerSlot(slot, posX,posY));
            }
        }
    }
    @Override
    public void containerTick() {
    }

    @Override
    public void render(GuiGraphicsExtractor guiGraphics, int mouseX, int mouseY, float partialTick) {
        super.render(guiGraphics, mouseX, mouseY, partialTick);
        renderCraftingResult(guiGraphics);
        renderContextAction(guiGraphics, mouseX, mouseY);
        renderQuickActions(guiGraphics, mouseX, mouseY, false);
        renderUtilityActions(guiGraphics, mouseX, mouseY, false);
        renderCreativeModeAction(guiGraphics, mouseX, mouseY, false);
        // Health, hunger, armor, and experience are all client-thread state.
        // Capture them once so the normal and tooltip passes render the same
        // frame without allocating and polling the player twice.
        StatusLayout statusLayout = captureStatusLayout();
        StatusSnapshot statusSnapshot = statusLayout == null
                ? null
                : getStatusSnapshot();
        renderStatusStrip(
                guiGraphics,
                mouseX,
                mouseY,
                statusLayout,
                statusSnapshot,
                false
        );
        this.renderTooltip(guiGraphics, mouseX, mouseY);
        renderStatusStrip(
                guiGraphics,
                mouseX,
                mouseY,
                statusLayout,
                statusSnapshot,
                true
        );
        renderQuickActions(guiGraphics, mouseX, mouseY, true);
        renderUtilityActions(guiGraphics, mouseX, mouseY, true);
        renderCreativeModeAction(guiGraphics, mouseX, mouseY, true);

        this.xMouse = (float)mouseX;
        this.yMouse = (float)mouseY;
    }

    public void setContextAction(@Nullable Component label,
                                 @Nullable Runnable action) {
        contextActionLabel = label;
        contextAction = action;
        invalidateCombinedBounds();
    }
    public void setCreativeModeAction(@Nullable Runnable action) {
        creativeModeAction = action;
        invalidateCombinedBounds();
    }

    private void renderCreativeModeAction(GuiGraphicsExtractor graphics,
                                          int mouseX,
                                          int mouseY,
                                          boolean tooltipPass) {
        if (!isCreativeModeActionVisible()) {
            return;
        }
        boolean hovered = isOverCreativeModeAction(mouseX, mouseY);
        if (tooltipPass) {
            if (hovered) {
                graphics.setTooltipForNextFrame(
                        font,
                        CREATIVE_MODE_ACTION_TOOLTIP,
                        mouseX,
                        mouseY
                );
            }
            return;
        }

        int x = getCreativeModeActionX();
        int y = getCreativeModeActionY();
        int background = hovered ? 0xEA454545 : 0xDA202020;
        int border = hovered ? 0xFFFFFFFF : 0xFF9A9A9A;
        graphics.fill(
                x,
                y,
                x + CREATIVE_MODE_ACTION_WIDTH,
                y + CREATIVE_MODE_ACTION_HEIGHT,
                background
        );
        graphics.fill(x, y, x + CREATIVE_MODE_ACTION_WIDTH, y + 1, border);
        graphics.fill(
                x,
                y + CREATIVE_MODE_ACTION_HEIGHT - 1,
                x + CREATIVE_MODE_ACTION_WIDTH,
                y + CREATIVE_MODE_ACTION_HEIGHT,
                border
        );
        graphics.fill(x, y, x + 1, y + CREATIVE_MODE_ACTION_HEIGHT, border);
        graphics.fill(
                x + CREATIVE_MODE_ACTION_WIDTH - 1,
                y,
                x + CREATIVE_MODE_ACTION_WIDTH,
                y + CREATIVE_MODE_ACTION_HEIGHT,
                border
        );
        graphics.centeredText(
                font,
                CREATIVE_MODE_ACTION_LABEL,
                x + CREATIVE_MODE_ACTION_WIDTH / 2,
                y + (CREATIVE_MODE_ACTION_HEIGHT - 8) / 2,
                0xFFFFFFFF
        );
    }

    private boolean isCreativeModeActionVisible() {
        return fullInventory
                && creativeModeAction != null
                && minecraft != null
                && minecraft.player != null
                && minecraft.gameMode != null
                && minecraft.gameMode.getPlayerMode().isCreative()
                && menu == minecraft.player.inventoryMenu
                && minecraft.player.containerMenu == minecraft.player.inventoryMenu;
    }

    private int getCreativeModeActionX() {
        return creativeModeActionX(leftPos, imageWidth);
    }

    private int getCreativeModeActionY() {
        return creativeModeActionY(topPos, getStatusLayout());
    }

    static int creativeModeActionX(int leftPos, int imageWidth) {
        return leftPos + (imageWidth - CREATIVE_MODE_ACTION_WIDTH) / 2;
    }

    static int creativeModeActionY(int topPos, StatusLayout statusLayout) {
        int topEdge = topPos;
        for (StatusGroup group : statusLayout.groups()) {
            if (group.position() == WristHudPosition.TOP) {
                topEdge = Math.min(topEdge, group.bounds().y());
            }
        }
        return topEdge - CREATIVE_MODE_ACTION_HEIGHT - CREATIVE_MODE_ACTION_GAP;
    }

    private boolean isOverCreativeModeAction(double mouseX, double mouseY) {
        int x = getCreativeModeActionX();
        int y = getCreativeModeActionY();
        return mouseX >= x && mouseX < x + CREATIVE_MODE_ACTION_WIDTH
                && mouseY >= y && mouseY < y + CREATIVE_MODE_ACTION_HEIGHT;
    }

    static InventoryBounds creativeModeActionBounds(int leftPos,
                                                     int topPos,
                                                     int imageWidth,
                                                     StatusLayout statusLayout) {
        return new InventoryBounds(
                creativeModeActionX(leftPos, imageWidth),
                creativeModeActionY(topPos, statusLayout),
                CREATIVE_MODE_ACTION_WIDTH,
                CREATIVE_MODE_ACTION_HEIGHT
        );
    }

    public void setUtilityAction(@NotNull String ownerId,
                                 @NotNull ItemStack icon,
                                 @NotNull Component tooltip,
                                 @NotNull BooleanSupplier visible,
                                 @NotNull Runnable action) {
        setUtilityAction(ownerId, icon, tooltip, visible, () -> false, action);
    }

    public void setUtilityAction(@NotNull String ownerId,
                                 @NotNull ItemStack icon,
                                 @NotNull Component tooltip,
                                 @NotNull BooleanSupplier visible,
                                 @NotNull BooleanSupplier toggled,
                                 @NotNull Runnable action) {
        utilityActions.put(ownerId, new UtilityAction(
                icon.copy(),
                tooltip,
                visible,
                toggled,
                action
        ));
        invalidateCombinedBounds();
    }

    public void clearUtilityAction(@NotNull String ownerId) {
        if (utilityActions.remove(ownerId) != null) {
            invalidateCombinedBounds();
        }
    }

    /**
     * Renders addon shortcuts in the unused upper-right corner of the player
     * portrait. Keeping the actions inside the existing panel avoids claiming
     * more wrist space and leaves the opposite arm available for other UIs.
     */
    private void renderUtilityActions(GuiGraphicsExtractor graphics,
                                      int mouseX,
                                      int mouseY,
                                      boolean tooltipPass) {
        List<UtilityAction> visibleActions = visibleUtilityActions();
        for (int index = 0; index < visibleActions.size(); index++) {
            UtilityAction action = visibleActions.get(index);
            int x = getUtilityActionX(index);
            int y = getUtilityActionY(index);
            boolean hovered = isOverUtilityAction(mouseX, mouseY, index);

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
                    x,
                    y,
                    x + UTILITY_ACTION_SIZE,
                    y + UTILITY_ACTION_SIZE,
                    background
            );
            graphics.fill(x, y, x + UTILITY_ACTION_SIZE, y + 1, border);
            graphics.fill(
                    x,
                    y + UTILITY_ACTION_SIZE - 1,
                    x + UTILITY_ACTION_SIZE,
                    y + UTILITY_ACTION_SIZE,
                    border
            );
            graphics.fill(x, y, x + 1, y + UTILITY_ACTION_SIZE, border);
            graphics.fill(
                    x + UTILITY_ACTION_SIZE - 1,
                    y,
                    x + UTILITY_ACTION_SIZE,
                    y + UTILITY_ACTION_SIZE,
                    border
            );
            graphics.item(action.icon(), x + 2, y + 2);
        }
    }

    private List<UtilityAction> visibleUtilityActions() {
        return visibleUtilityActionCache.refresh(
                fullInventory,
                utilityActions.values(),
                UtilityAction::isVisible
        );
    }

    private int getUtilityActionX(int index) {
        // The compact addon shortcut occupies the small bridge at the
        // portrait's upper-right, immediately before the circular hotbar. This
        // is the blue-marked position in the wrist-inventory layout and keeps
        // the six configurable actions around the lower inventory unobstructed.
        return utilityActionX(leftPos, index);
    }

    private int getUtilityActionY(int index) {
        return utilityActionY(topPos, index);
    }

    static int utilityActionX(int leftPos, int index) {
        return leftPos + 58;
    }

    static int utilityActionY(int topPos, int index) {
        return topPos + 4 + index * (UTILITY_ACTION_SIZE + UTILITY_ACTION_GAP);
    }

    static InventoryBounds utilityActionBounds(int leftPos, int topPos, int index) {
        return new InventoryBounds(
                utilityActionX(leftPos, index),
                utilityActionY(topPos, index),
                UTILITY_ACTION_SIZE,
                UTILITY_ACTION_SIZE
        );
    }

    private boolean isOverUtilityAction(double mouseX,
                                        double mouseY,
                                        int index) {
        int x = getUtilityActionX(index);
        int y = getUtilityActionY(index);
        return mouseX >= x && mouseX < x + UTILITY_ACTION_SIZE
                && mouseY >= y && mouseY < y + UTILITY_ACTION_SIZE;
    }

    /**
     * Draws up to twelve user-configurable shortcuts as connected tabs around
     * the lower inventory panel. Slots 0-2 and 3-5 retain the original inner
     * left/right columns; slots 6-8 and 9-11 add outer left/right columns.
     * Their bounds stop before the nearest item slot, so a laser click can
     * never be mistaken for an inventory interaction.
     */
    private void renderQuickActions(GuiGraphicsExtractor graphics,
                                    int mouseX,
                                    int mouseY,
                                    boolean tooltipPass) {
        int visibleCount = getVisibleQuickActionCount();
        if (!fullInventory || visibleCount == 0) {
            return;
        }

        QuickActionManager manager = QuickActionManager.getInstance();
        for (int slot = 0; slot < visibleCount; slot++) {
            int x = getQuickActionX(slot);
            int y = getQuickActionY(slot);
            boolean hovered = isOverQuickAction(mouseX, mouseY, slot);

            if (tooltipPass) {
                if (hovered) {
                    Component editHint = manager.isConfigured(slot)
                            ? Component.literal("Right-click or Shift-click to edit")
                                    .withStyle(ChatFormatting.GRAY)
                            : Component.literal("Choose a keybind or command")
                                    .withStyle(ChatFormatting.GRAY);
                    graphics.setTooltipForNextFrame(
                            font,
                            List.of(manager.getTooltip(slot), editHint),
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
            graphics.fill(x, y, x + QUICK_ACTION_SIZE, y + 1, border);
            graphics.fill(
                    x,
                    y + QUICK_ACTION_SIZE - 1,
                    x + QUICK_ACTION_SIZE,
                    y + QUICK_ACTION_SIZE,
                    border
            );
            graphics.fill(x, y, x + 1, y + QUICK_ACTION_SIZE, border);
            graphics.fill(
                    x + QUICK_ACTION_SIZE - 1,
                    y,
                    x + QUICK_ACTION_SIZE,
                    y + QUICK_ACTION_SIZE,
                    border
            );

            ItemStack icon = getQuickActionIcon(manager, slot);
            if (icon.isEmpty()) {
                graphics.centeredText(
                        font,
                        "+",
                        x + QUICK_ACTION_SIZE / 2,
                        y + (QUICK_ACTION_SIZE - 8) / 2,
                        0xFFFFFFFF
                );
            } else {
                graphics.item(icon, x + 2, y + 2);
            }
        }
    }

    private @NotNull ItemStack getQuickActionIcon(@NotNull QuickActionManager manager,
                                                   int slot) {
        QuickActionDefinition action = manager.getAction(slot);
        ItemStack cached = quickActionIconCache.getIfCurrent(slot, action);
        if (cached != null) {
            return cached;
        }

        ItemStack icon = manager.getIconStack(action);
        quickActionIconCache.put(slot, action, icon);
        return icon;
    }

    private int getVisibleQuickActionCount() {
        QuickActionDisplayMode mode = WristUiConfig.getInstance().quickActionDisplayMode();
        return Math.min(mode.visibleSlots(), QuickActionManager.SLOT_COUNT);
    }

    private int getQuickActionX(int slot) {
        return quickActionX(leftPos, slot);
    }

    static int quickActionX(int leftPos, int slot) {
        int offset = switch (slot / 3) {
            case 0 -> QUICK_ACTION_LEFT_X;
            case 1 -> QUICK_ACTION_RIGHT_X;
            case 2 -> QUICK_ACTION_OUTER_LEFT_X;
            case 3 -> QUICK_ACTION_OUTER_RIGHT_X;
            default -> throw new IndexOutOfBoundsException("Quick action slot: " + slot);
        };
        return leftPos + offset;
    }

    private int getQuickActionY(int slot) {
        return quickActionY(topPos, slot);
    }

    static int quickActionY(int topPos, int slot) {
        int row = slot % 3;
        return topPos + QUICK_ACTION_FIRST_Y
                + row * (QUICK_ACTION_SIZE + QUICK_ACTION_GAP);
    }

    static InventoryBounds quickActionBounds(int leftPos, int topPos, int slot) {
        return new InventoryBounds(
                quickActionX(leftPos, slot),
                quickActionY(topPos, slot),
                QUICK_ACTION_SIZE,
                QUICK_ACTION_SIZE
        );
    }

    private boolean isOverQuickAction(double mouseX,
                                      double mouseY,
                                      int slot) {
        int x = getQuickActionX(slot);
        int y = getQuickActionY(slot);
        return mouseX >= x && mouseX < x + QUICK_ACTION_SIZE
                && mouseY >= y && mouseY < y + QUICK_ACTION_SIZE;
    }

    private void clickQuickAction(int slot, boolean edit) {
        QuickActionManager manager = QuickActionManager.getInstance();
        playQuickActionClick();
        if (edit || !manager.isConfigured(slot)) {
            QuickActionEditorScreen.open(slot);
        } else {
            manager.execute(slot);
        }
    }

    private void playQuickActionClick() {
        Minecraft.getInstance().getSoundManager().play(
                SimpleSoundInstance.forUI(SoundEvents.UI_BUTTON_CLICK, 1.0F)
        );
    }

    /** Renders the configurable, always-live HUD around the wrist inventory. */
    private void renderStatusStrip(GuiGraphicsExtractor graphics,
                                   int mouseX,
                                   int mouseY,
                                   @Nullable StatusLayout layout,
                                   @Nullable StatusSnapshot snapshot,
                                   boolean tooltipPass) {
        if (layout == null || snapshot == null) {
            return;
        }
        if (tooltipPass) {
            StatusCell hovered = getHoveredStatusCell(layout, mouseX, mouseY);
            if (hovered != null) {
                graphics.setTooltipForNextFrame(
                        font,
                        getStatusTooltip(hovered.metric(), snapshot),
                        Optional.empty(),
                        mouseX,
                        mouseY
                );
            }
            return;
        }

        for (StatusGroup group : layout.groups()) {
            drawStatusGroupBackground(graphics, group);
        }

        for (StatusCell cell : layout.cells()) {
            drawVanillaHorizontalMetric(graphics, cell, snapshot);
        }
    }

    private StatusSnapshot getStatusSnapshot() {
        var player = minecraft.player;
        var foodData = player.getFoodData();
        float maximumHealth = finiteNonNegative(player.getMaxHealth());
        float health = Math.min(finiteNonNegative(player.getHealth()), maximumHealth);
        float absorption = finiteNonNegative(player.getAbsorptionAmount());
        int hunger = Math.max(0, Math.min(20, foodData.getFoodLevel()));
        float saturation = Math.max(
                0.0F,
                Math.min(20.0F, finiteNonNegative(foodData.getSaturationLevel()))
        );
        return statusSnapshot.update(
                maximumHealth,
                health,
                absorption,
                hunger,
                saturation,
                Math.max(0, player.getArmorValue()),
                Math.max(0, player.experienceLevel),
                clampRatio(player.experienceProgress)
        );
    }

    private List<Component> getStatusTooltip(WristHudMetric metric,
                                             StatusSnapshot snapshot) {
        return switch (metric) {
            case HEALTH -> snapshot.absorption() > 0.0F
                    ? List.of(
                            Component.literal("Health: " + formatAmount(snapshot.health())
                                    + " / " + formatAmount(snapshot.maximumHealth())),
                            Component.literal("Absorption: +"
                                            + formatAmount(snapshot.absorption()))
                                    .withStyle(ChatFormatting.GOLD)
                    )
                    : List.of(Component.literal(
                            "Health: " + formatAmount(snapshot.health())
                                    + " / " + formatAmount(snapshot.maximumHealth())
                    ));
            case HUNGER -> List.of(
                    Component.literal("Hunger: " + snapshot.hunger() + " / 20"),
                    Component.literal("Saturation: " + formatAmount(snapshot.saturation()))
                            .withStyle(ChatFormatting.GOLD)
            );
            case ARMOR -> List.of(Component.literal("Armor: " + snapshot.armor()));
            case EXPERIENCE -> List.of(Component.literal(
                    "Experience: Level " + snapshot.experienceLevel() + " ("
                            + Math.round(snapshot.experienceProgress() * 100.0F) + "%)"
            ));
        };
    }

    private StatusLayout getStatusLayout() {
        WristUiConfig config = WristUiConfig.getInstance();
        long configRevision = config.revision();
        boolean rebuild = layoutCacheState.shouldRebuildStatusLayout(
                leftPos,
                topPos,
                imageHeight,
                configRevision
        );
        if (rebuild || cachedStatusLayout == null) {
            cachedStatusLayout = buildStatusLayout(config);
        }
        return cachedStatusLayout;
    }

    private StatusLayout buildStatusLayout(WristUiConfig config) {
        List<StatusGroup> groups = new ArrayList<>();
        List<StatusCell> cells = new ArrayList<>();

        for (WristHudPosition position : WristHudPosition.values()) {
            List<WristHudMetric> metrics = new ArrayList<>();
            for (WristHudMetric metric : WristHudMetric.values()) {
                if (config.isVisible(metric) && config.position(metric) == position) {
                    metrics.add(metric);
                }
            }
            if (metrics.isEmpty()) {
                continue;
            }

            StatusGroup group = buildHorizontalStatusGroup(position, metrics);
            groups.add(group);
            cells.addAll(group.cells());
        }
        return new StatusLayout(List.copyOf(groups), List.copyOf(cells));
    }

    private StatusGroup buildHorizontalStatusGroup(WristHudPosition position,
                                                   List<WristHudMetric> metrics) {
        int columns = Math.min(2, metrics.size());
        int rows = (metrics.size() + 1) / 2;
        int width = columns * STATUS_METRIC_WIDTH;
        int height = rows * STATUS_METRIC_HEIGHT + 1;
        int x = leftPos + STATUS_STRIP_X + (STATUS_STRIP_WIDTH - width) / 2;
        int y = position == WristHudPosition.BOTTOM
                ? topPos + imageHeight - 1
                : topPos - height + 1;

        List<StatusCell> cells = new ArrayList<>();
        for (int index = 0; index < metrics.size(); index++) {
            int column = index % 2;
            int row = index / 2;
            boolean centeredLastCell = columns == 2
                    && index == metrics.size() - 1
                    && metrics.size() % 2 != 0;
            int cellX = centeredLastCell
                    ? x + (width - STATUS_METRIC_WIDTH) / 2
                    : x + column * STATUS_METRIC_WIDTH;
            cells.add(new StatusCell(
                    metrics.get(index),
                    new InventoryBounds(
                            cellX,
                            y + 1 + row * STATUS_METRIC_HEIGHT,
                            STATUS_METRIC_WIDTH,
                            STATUS_METRIC_HEIGHT
                    )
            ));
        }
        return new StatusGroup(
                position,
                new InventoryBounds(x, y, width, height),
                columns,
                rows,
                List.copyOf(cells)
        );
    }

    private void drawStatusGroupBackground(GuiGraphicsExtractor graphics, StatusGroup group) {
        InventoryBounds bounds = group.bounds();
        int x = bounds.x();
        int y = bounds.y();
        int width = bounds.width();
        int height = bounds.height();
        int border = 0xFF9A9A9A;

        graphics.fill(x, y, x + width, y + height, 0xEC171717);
        graphics.fill(x, y, x + width, y + 1, border);
        graphics.fill(x, y + height - 1, x + width, y + height, border);
        graphics.fill(x, y, x + 1, y + height, border);
        graphics.fill(x + width - 1, y, x + width, y + height, border);

        for (int row = 0; row < group.rows(); row++) {
            int cellsInRow = Math.min(
                    group.columns(),
                    group.cells().size() - row * group.columns()
            );
            if (cellsInRow > 1) {
                int separatorX = x + STATUS_METRIC_WIDTH;
                int separatorTop = y + 1 + row * STATUS_METRIC_HEIGHT;
                int separatorBottom = y + (row + 1) * STATUS_METRIC_HEIGHT;
                graphics.fill(
                        separatorX,
                        separatorTop,
                        separatorX + 1,
                        separatorBottom,
                        0xFF505050
                );
            }
        }
        for (int row = 1; row < group.rows(); row++) {
            int separatorY = y + row * STATUS_METRIC_HEIGHT;
            graphics.fill(x + 1, separatorY, x + width - 1,
                    separatorY + 1, 0xFF505050);
        }
    }

    private void drawVanillaHorizontalMetric(GuiGraphicsExtractor graphics,
                                             StatusCell cell,
                                             StatusSnapshot snapshot) {
        InventoryBounds bounds = cell.bounds();
        if (cell.metric() == WristHudMetric.EXPERIENCE) {
            String level = Integer.toString(snapshot.experienceLevel());
            graphics.centeredText(font, level,
                    bounds.x() + bounds.width() / 2, bounds.y() + 1, 0xFF80FF20);
            drawVanillaExperienceBar(
                    graphics,
                    bounds.x() + 3,
                    bounds.y() + 10,
                    81,
                    snapshot.experienceProgress()
            );
            return;
        }
        drawVanillaMetricIcons(
                graphics,
                cell.metric(),
                snapshot,
                bounds.x() + 3,
                bounds.y() + 2
        );
    }

    private void drawVanillaMetricIcons(GuiGraphicsExtractor graphics,
                                        WristHudMetric metric,
                                        StatusSnapshot snapshot,
                                        int x,
                                        int y) {
        Identifier empty = switch (metric) {
            case HEALTH -> HEALTH_CONTAINER_ICON;
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
        float healthDisplayCapacity = Math.max(
                snapshot.maximumHealth(),
                snapshot.health() + snapshot.absorption()
        );
        int units = switch (metric) {
            case HEALTH -> Math.round(
                    safeRatio(snapshot.health(), healthDisplayCapacity) * 20.0F
            );
            case HUNGER -> snapshot.hunger();
            case ARMOR -> Math.min(snapshot.armor(), 20);
            case EXPERIENCE -> 0;
        };
        int absorptionUnits = metric == WristHudMetric.HEALTH
                && snapshot.absorption() > 0.0F
                ? Math.max(
                        1,
                        Math.round(
                                safeRatio(
                                        snapshot.absorption(),
                                        healthDisplayCapacity
                                ) * 20.0F
                        )
                )
                : 0;
        // A rounded 19- or 20-unit health display leaves no complete icon
        // slot for absorption. Reserve the last slot so even a small shield is
        // visible instead of silently disappearing at full health.
        if (absorptionUnits > 0 && units > 18) {
            units = 18;
        }
        absorptionUnits = Math.min(20 - units, absorptionUnits);

        boolean compatibilityRendererHandled = false;
        if (metric == WristHudMetric.HEALTH && minecraft.player != null) {
            compatibilityRendererHandled = ColorfulHeartsCompat.drawHorizontalHealth(
                    graphics,
                    minecraft.player,
                    x,
                    y
            );
        } else if (metric == WristHudMetric.ARMOR) {
            compatibilityRendererHandled = OverloadedArmorBarCompat.drawHorizontalArmor(
                    graphics,
                    snapshot.armor(),
                    x,
                    y
            );
        }

        if (!compatibilityRendererHandled) {
            for (int slot = 0; slot < 10; slot++) {
                drawVanillaHudSprite(graphics, empty, x, y, slot);
                int threshold = slot * 2;
                if (units >= threshold + 2) {
                    drawVanillaHudSprite(graphics, full, x, y, slot);
                } else if (units == threshold + 1) {
                    drawVanillaHudSprite(graphics, half, x, y, slot);
                }
            }
        }

        if (absorptionUnits > 0) {
            int slot = Math.min(10, (units + 1) / 2);
            while (absorptionUnits > 0 && slot < 10) {
                Identifier sprite = absorptionUnits >= 2
                        ? ABSORPTION_FULL_ICON
                        : ABSORPTION_HALF_ICON;
                drawVanillaHudSprite(graphics, sprite, x, y, slot);
                absorptionUnits -= 2;
                slot++;
            }
        }
    }

    private void drawVanillaHudSprite(GuiGraphicsExtractor graphics,
                                      Identifier sprite,
                                      int x,
                                      int y,
                                      int slot) {
        graphics.blitSprite(RenderPipelines.GUI_TEXTURED,
                sprite, x + slot * 8, y, 9, 9);
    }

    private void drawVanillaExperienceBar(GuiGraphicsExtractor graphics,
                                          int x,
                                          int y,
                                          int width,
                                          float progress) {
        graphics.blitSprite(RenderPipelines.GUI_TEXTURED,
                EXPERIENCE_BACKGROUND, x, y, width, 5);
        int progressWidth = Math.round(clampRatio(progress) * width);
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

    private @Nullable StatusCell getHoveredStatusCell(StatusLayout layout,
                                                      double mouseX,
                                                      double mouseY) {
        for (StatusCell cell : layout.cells()) {
            if (contains(cell.bounds(), mouseX, mouseY)) {
                return cell;
            }
        }
        return null;
    }

    private boolean isOverStatusStrip(double mouseX, double mouseY) {
        if (!fullInventory) {
            return false;
        }
        for (StatusGroup group : getStatusLayout().groups()) {
            if (contains(group.bounds(), mouseX, mouseY)) {
                return true;
            }
        }
        return false;
    }

    static boolean contains(InventoryBounds bounds,
                            double mouseX,
                            double mouseY) {
        return mouseX >= bounds.x() && mouseX < bounds.x() + bounds.width()
                && mouseY >= bounds.y() && mouseY < bounds.y() + bounds.height();
    }

    private static float finiteNonNegative(float value) {
        return Float.isFinite(value) ? Math.max(0.0F, value) : 0.0F;
    }

    private static float safeRatio(float value, float maximum) {
        if (!Float.isFinite(maximum) || maximum <= 0.0F) {
            return 0.0F;
        }
        return clampRatio(value / maximum);
    }

    private static float clampRatio(float ratio) {
        if (!Float.isFinite(ratio)) {
            return 0.0F;
        }
        return Math.max(0.0F, Math.min(1.0F, ratio));
    }

    private static String formatAmount(float value) {
        float safeValue = finiteNonNegative(value);
        int rounded = Math.round(safeValue);
        if (Math.abs(safeValue - rounded) < 0.05F) {
            return Integer.toString(rounded);
        }
        return Float.toString(Math.round(safeValue * 10.0F) / 10.0F);
    }

    private void renderContextAction(GuiGraphicsExtractor graphics,
                                     int mouseX,
                                     int mouseY) {
        if (contextActionLabel == null || contextAction == null) {
            return;
        }

        int x = getContextActionX();
        int y = getContextActionY();
        boolean hovered = isOverContextAction(mouseX, mouseY);
        boolean enabled = menu.getCarried().isEmpty();
        int background = !enabled
                ? 0xB0181818
                : hovered ? 0xE0434343 : 0xD02B2B2B;
        int border = !enabled
                ? 0xFF555555
                : hovered ? 0xFFFFFFFF : 0xFFA9A9A9;
        Component label = enabled
                ? contextActionLabel
                : Component.literal("Place Held Item First");

        graphics.fill(x, y, x + CONTEXT_ACTION_WIDTH,
                y + CONTEXT_ACTION_HEIGHT, background);
        graphics.fill(x, y, x + 4, y + CONTEXT_ACTION_HEIGHT, 0xFFE84A52);
        graphics.fill(x, y, x + CONTEXT_ACTION_WIDTH, y + 1, border);
        graphics.fill(x, y + CONTEXT_ACTION_HEIGHT - 1,
                x + CONTEXT_ACTION_WIDTH, y + CONTEXT_ACTION_HEIGHT, border);
        graphics.fill(x, y, x + 1, y + CONTEXT_ACTION_HEIGHT, border);
        graphics.fill(x + CONTEXT_ACTION_WIDTH - 1, y,
                x + CONTEXT_ACTION_WIDTH, y + CONTEXT_ACTION_HEIGHT, border);
        graphics.centeredText(
                font,
                label,
                x + CONTEXT_ACTION_WIDTH / 2,
                y + (CONTEXT_ACTION_HEIGHT - 8) / 2,
                enabled ? 0xFFFFFFFF : 0xFF888888
        );
    }

    private int getContextActionX() {
        return contextActionX(leftPos, imageWidth);
    }

    private int getContextActionY() {
        StatusLayout statusLayout = fullInventory
                ? getStatusLayout()
                : StatusLayout.EMPTY;
        return contextActionY(topPos, imageHeight, fullInventory, statusLayout);
    }

    static int contextActionX(int leftPos, int imageWidth) {
        return leftPos + (imageWidth - CONTEXT_ACTION_WIDTH) / 2;
    }

    static int contextActionY(int topPos,
                              int imageHeight,
                              boolean fullInventory,
                              StatusLayout statusLayout) {
        int lowerEdge = topPos + imageHeight;
        if (fullInventory) {
            for (StatusGroup group : statusLayout.groups()) {
                if (group.position() == WristHudPosition.BOTTOM) {
                    lowerEdge = Math.max(
                            lowerEdge,
                            group.bounds().y() + group.bounds().height()
                    );
                }
            }
        }
        return lowerEdge + CONTEXT_ACTION_GAP;
    }

    static InventoryBounds contextActionBounds(int leftPos,
                                                int topPos,
                                                int imageWidth,
                                                int imageHeight,
                                                boolean fullInventory,
                                                StatusLayout statusLayout) {
        return new InventoryBounds(
                contextActionX(leftPos, imageWidth),
                contextActionY(topPos, imageHeight, fullInventory, statusLayout),
                CONTEXT_ACTION_WIDTH,
                CONTEXT_ACTION_HEIGHT
        );
    }

    private boolean isOverContextAction(double mouseX, double mouseY) {
        int x = getContextActionX();
        int y = getContextActionY();
        return mouseX >= x && mouseX < x + CONTEXT_ACTION_WIDTH
                && mouseY >= y && mouseY < y + CONTEXT_ACTION_HEIGHT;
    }

    /**
     * FastWorkbench only applies its client crafting-result payload when a
     * normal inventory screen is open. This wrist inventory deliberately runs
     * with Minecraft.screen == null, so its result slot can remain visually
     * empty even though the server accepts clicks and crafts the item. Prefer
     * the real result when available, otherwise render a cached client recipe
     * preview after the container pass at the final wrist-panel coordinates.
     */
    private void renderCraftingResult(GuiGraphicsExtractor guiGraphics) {
        if (!fullInventory) {
            return;
        }

        ItemStack result = ItemStack.EMPTY;
        for (Slot slot : menu.slots) {
            if (slot instanceof ResultSlot) {
                result = slot.getItem();
                break;
            }
        }

        if (result.isEmpty()) {
            return;
        }

        int x = leftPos + CRAFT_RESULT_X;
        int y = topPos + CRAFT_RESULT_Y;

        guiGraphics.item(result, x, y);
        guiGraphics.itemDecorations(font, result, x, y, null);
    }

    /**
     * The result is deliberately drawn after the inherited container pass by
     * {@link #renderCraftingResult(GuiGraphicsExtractor)}. Suppress the inherited slot
     * draw so the output has one deterministic rendering path.
     */
    @Override
    protected void extractSlot(GuiGraphicsExtractor guiGraphics,
                               Slot slot,
                               int x,
                               int y) {
        if (fullInventory && slot instanceof ResultSlot) {
            return;
        }
        super.extractSlot(guiGraphics, slot, x, y);
    }


    @Override
    protected void renderBg(GuiGraphicsExtractor guiGraphics, float partialTick, int mouseX, int mouseY) {
        int i = this.leftPos;
        int j = this.topPos;

        guiGraphics.blit(RenderPipelines.GUI_TEXTURED,
                fullInventory ? IMAGE_FULL : IMAGE_SIMPLIFIED,
                width/2-258/2, height/2-156/2,
                0.0F, 0.0F,
                258, 156,
                258,156
        );

        if(fullInventory) {
            InventoryScreen.extractEntityInInventoryFollowsMouse(
                    guiGraphics,
                    i + 26,
                    j + 8,
                    i + 75,
                    j + 78,
                    30,
                    0.0625F,
                    this.xMouse,
                    this.yMouse,
                    this.minecraft.player
            );
        }
    }

    public boolean mouseClicked(double mouseX, double mouseY, int button) {
        if (button == 0
                && isCreativeModeActionVisible()
                && isOverCreativeModeAction(mouseX, mouseY)) {
            minecraft.getSoundManager().play(
                    SimpleSoundInstance.forUI(SoundEvents.UI_BUTTON_CLICK, 1.0F)
            );
            creativeModeAction.run();
            return true;
        }

        int visibleQuickActions = getVisibleQuickActionCount();
        if (fullInventory
                && visibleQuickActions > 0
                && (button == 0 || button == 1)) {
            for (int slot = 0; slot < visibleQuickActions; slot++) {
                if (isOverQuickAction(mouseX, mouseY, slot)) {
                    boolean edit = button == 1 || Minecraft.getInstance().hasShiftDown();
                    clickQuickAction(slot, edit);
                    return true;
                }
            }
        }
        if (button == 0) {
            List<UtilityAction> visibleActions = visibleUtilityActions();
            for (int index = 0; index < visibleActions.size(); index++) {
                if (isOverUtilityAction(mouseX, mouseY, index)) {
                    visibleActions.get(index).action().run();
                    return true;
                }
            }
        }
        if (button == 0
                && contextAction != null
                && isOverContextAction(mouseX, mouseY)) {
            if (menu.getCarried().isEmpty()) {
                contextAction.run();
            }
            return true;
        }
        // The status footer extends beyond AbstractContainerScreen.imageHeight.
        // Consume clicks there so vanilla can never interpret a harmless HUD
        // press as an outside-inventory click and throw a carried stack.
        if (isOverStatusStrip(mouseX, mouseY)) {
            return true;
        }
        return super.mouseClicked(mouseX, mouseY, button);
    }

    /**
     * This nested inventory intentionally defines no desktop-style widgets.
     * NeoForge screen-init hooks still inject global modpack buttons such as
     * Dark Mode and the FTB sidebar, so remove those after public init() has
     * finished posting its pre/post events.
     */
    public void removeInjectedWidgets() {
        var injectedWidgets = children().stream()
                .filter(AbstractWidget.class::isInstance)
                .toList();
        injectedWidgets.forEach(this::removeWidget);
    }

    protected boolean hasClickedOutside(double mouseX, double mouseY, int guiLeft, int guiTop, int mouseButton) {
        InventoryBounds bounds = visorEssentials$getCombinedBounds();
        return mouseX < bounds.x()
                || mouseY < bounds.y()
                || mouseX >= bounds.x() + bounds.width()
                || mouseY >= bounds.y() + bounds.height();
    }



    @Override
    public int visorEssentials$getEdgeX() {
        return visorEssentials$getCombinedBounds().x();
    }

    @Override
    public int visorEssentials$getEdgeY() {
        return visorEssentials$getCombinedBounds().y();
    }

    @Override
    public int visorEssentials$getEdgeWidth() {
        return visorEssentials$getCombinedBounds().width();
    }

    @Override
    public int visorEssentials$getEdgeHeight() {
        return visorEssentials$getCombinedBounds().height();
    }

    /**
     * Returns one immutable snapshot for all four overlay cursor bounds. Callers
     * that need x/y/width/height together should use this method so dynamic
     * effect and addon visibility is sampled only once for that client tick.
     */
    public @NotNull InventoryBounds visorEssentials$getInteractionBounds() {
        return visorEssentials$getCombinedBounds();
    }

    /**
     * Cursor focus must cover exactly the same rectangle as the visible wrist
     * inventory. Include the dynamically sized status-effect strip instead of
     * relying on render state from the previous frame.
     */
    private InventoryBounds visorEssentials$getCombinedBounds() {
        StatusLayout statusLayout = fullInventory
                ? getStatusLayout()
                : StatusLayout.EMPTY;
        int visibleEffectCount = visorEssentials$getVisibleEffectCount();
        boolean contextActionVisible = contextActionLabel != null
                && contextAction != null;
        boolean creativeModeActionVisible = isCreativeModeActionVisible();
        int visibleQuickActions = fullInventory
                ? getVisibleQuickActionCount()
                : 0;
        int visibleUtilityActions = visibleUtilityActions().size();

        boolean rebuild = layoutCacheState.shouldRebuildCombinedBounds(
                leftPos,
                topPos,
                width,
                height,
                imageWidth,
                imageHeight,
                fullInventory,
                visibleEffectCount,
                contextActionVisible,
                creativeModeActionVisible,
                visibleQuickActions,
                visibleUtilityActions
        );
        if (rebuild || cachedCombinedBounds == null) {
            EffectBounds effectBounds = visorEssentials$getEffectBounds(
                    visibleEffectCount
            );
            InventoryBounds effects = effectBounds == null
                    ? null
                    : new InventoryBounds(
                            effectBounds.x(),
                            effectBounds.y(),
                            effectBounds.width(),
                            effectBounds.height()
                    );
            cachedCombinedBounds = calculateCombinedBounds(
                    leftPos,
                    topPos,
                    imageWidth,
                    imageHeight,
                    fullInventory,
                    effects,
                    statusLayout,
                    contextActionVisible,
                    creativeModeActionVisible,
                    visibleQuickActions,
                    visibleUtilityActions
            );
        }
        return cachedCombinedBounds;
    }

    private void invalidateCombinedBounds() {
        layoutCacheState.invalidateCombinedBounds();
    }

    static InventoryBounds calculateCombinedBounds(
            int leftPos,
            int topPos,
            int imageWidth,
            int imageHeight,
            boolean fullInventory,
            @Nullable InventoryBounds effects,
            StatusLayout statusLayout,
            boolean contextActionVisible,
            boolean creativeModeActionVisible,
            int visibleQuickActions,
            int visibleUtilityActions
    ) {
        int inventoryX = fullInventory ? leftPos : leftPos + 40;
        int inventoryY = topPos;
        int inventoryWidth = fullInventory ? imageWidth : imageWidth - 80;
        int inventoryHeight = imageHeight;

        int minX = inventoryX;
        int minY = inventoryY;
        int maxX = inventoryX + inventoryWidth;
        int maxY = inventoryY + inventoryHeight;

        if (effects != null) {
            minX = Math.min(minX, effects.x());
            minY = Math.min(minY, effects.y());
            maxX = Math.max(maxX, effects.x() + effects.width());
            maxY = Math.max(maxY, effects.y() + effects.height());
        }

        if (contextActionVisible) {
            int actionX = contextActionX(leftPos, imageWidth);
            int actionY = contextActionY(
                    topPos,
                    imageHeight,
                    fullInventory,
                    statusLayout
            );
            minX = Math.min(minX, actionX);
            minY = Math.min(minY, actionY);
            maxX = Math.max(maxX, actionX + CONTEXT_ACTION_WIDTH);
            maxY = Math.max(maxY, actionY + CONTEXT_ACTION_HEIGHT);
        }
        if (creativeModeActionVisible) {
            int actionX = creativeModeActionX(leftPos, imageWidth);
            int actionY = creativeModeActionY(topPos, statusLayout);
            minX = Math.min(minX, actionX);
            minY = Math.min(minY, actionY);
            maxX = Math.max(maxX, actionX + CREATIVE_MODE_ACTION_WIDTH);
            maxY = Math.max(maxY, actionY + CREATIVE_MODE_ACTION_HEIGHT);
        }
        if (fullInventory) {
            if (visibleQuickActions > 0) {
                for (int slot = 0; slot < visibleQuickActions; slot++) {
                    int actionX = quickActionX(leftPos, slot);
                    int actionY = quickActionY(topPos, slot);
                    minX = Math.min(minX, actionX);
                    minY = Math.min(minY, actionY);
                    maxX = Math.max(maxX, actionX + QUICK_ACTION_SIZE);
                    maxY = Math.max(maxY, actionY + QUICK_ACTION_SIZE);
                }
            }

            for (StatusGroup group : statusLayout.groups()) {
                InventoryBounds statusBounds = group.bounds();
                minX = Math.min(minX, statusBounds.x());
                minY = Math.min(minY, statusBounds.y());
                maxX = Math.max(maxX, statusBounds.x() + statusBounds.width());
                maxY = Math.max(maxY, statusBounds.y() + statusBounds.height());
            }

            for (int index = 0; index < visibleUtilityActions; index++) {
                int actionX = utilityActionX(leftPos, index);
                int actionY = utilityActionY(topPos, index);
                minX = Math.min(minX, actionX);
                minY = Math.min(minY, actionY);
                maxX = Math.max(maxX, actionX + UTILITY_ACTION_SIZE);
                maxY = Math.max(maxY, actionY + UTILITY_ACTION_SIZE);
            }
        }
        return new InventoryBounds(minX, minY, maxX - minX, maxY - minY);
    }

    public record InventoryBounds(int x, int y, int width, int height) {}

    record StatusCell(WristHudMetric metric,
                      InventoryBounds bounds) {}

    record StatusGroup(WristHudPosition position,
                       InventoryBounds bounds,
                       int columns,
                       int rows,
                       List<StatusCell> cells) {}

    record StatusLayout(List<StatusGroup> groups,
                        List<StatusCell> cells) {
        static final StatusLayout EMPTY = new StatusLayout(List.of(), List.of());
    }

    static final class StatusSnapshot {
        private float maximumHealth;
        private float health;
        private float absorption;
        private int hunger;
        private float saturation;
        private int armor;
        private int experienceLevel;
        private float experienceProgress;

        StatusSnapshot update(float maximumHealth,
                              float health,
                              float absorption,
                              int hunger,
                              float saturation,
                              int armor,
                              int experienceLevel,
                              float experienceProgress) {
            this.maximumHealth = maximumHealth;
            this.health = health;
            this.absorption = absorption;
            this.hunger = hunger;
            this.saturation = saturation;
            this.armor = armor;
            this.experienceLevel = experienceLevel;
            this.experienceProgress = experienceProgress;
            return this;
        }

        float maximumHealth() {
            return maximumHealth;
        }

        float health() {
            return health;
        }

        float absorption() {
            return absorption;
        }

        int hunger() {
            return hunger;
        }

        float saturation() {
            return saturation;
        }

        int armor() {
            return armor;
        }

        int experienceLevel() {
            return experienceLevel;
        }

        float experienceProgress() {
            return experienceProgress;
        }
    }

    private record UtilityAction(ItemStack icon,
                                 Component tooltip,
                                 BooleanSupplier visible,
                                 BooleanSupplier toggled,
                                 Runnable action) {
        boolean isVisible() {
            return visible.getAsBoolean();
        }
    }

    private @Nullable StatusLayout captureStatusLayout() {
        if (!fullInventory || minecraft.player == null) {
            return null;
        }
        StatusLayout layout = getStatusLayout();
        return layout.groups().isEmpty() ? null : layout;
    }

    static final class VisibleActionCache<T> {
        private final List<T> visibleActions = new ArrayList<>();

        List<T> refresh(boolean enabled,
                        Iterable<T> actions,
                        Predicate<T> isVisible) {
            int visibleIndex = 0;
            if (enabled) {
                for (T action : actions) {
                    if (!isVisible.test(action)) {
                        continue;
                    }
                    if (visibleIndex < visibleActions.size()) {
                        visibleActions.set(visibleIndex, action);
                    } else {
                        visibleActions.add(action);
                    }
                    visibleIndex++;
                }
            }

            while (visibleActions.size() > visibleIndex) {
                visibleActions.remove(visibleActions.size() - 1);
            }
            return visibleActions;
        }
    }

    static final class IndexedValueCache<K, V> {
        private final Object[] keys;
        private final Object[] values;
        private final boolean[] initialized;

        IndexedValueCache(int size) {
            if (size <= 0) {
                throw new IllegalArgumentException("Cache size must be positive");
            }
            keys = new Object[size];
            values = new Object[size];
            initialized = new boolean[size];
        }

        @SuppressWarnings("unchecked")
        @Nullable V getIfCurrent(int index, K key) {
            checkIndex(index);
            return initialized[index] && Objects.equals(keys[index], key)
                    ? (V) values[index]
                    : null;
        }

        void put(int index, K key, @NotNull V value) {
            checkIndex(index);
            keys[index] = key;
            values[index] = Objects.requireNonNull(value, "value");
            initialized[index] = true;
        }

        private void checkIndex(int index) {
            if (index < 0 || index >= keys.length) {
                throw new IndexOutOfBoundsException("Cache index: " + index);
            }
        }
    }

    static final class LayoutCacheState {
        private boolean statusLayoutValid;
        private int statusLeftPos;
        private int statusTopPos;
        private int statusImageHeight;
        private long statusConfigRevision;
        private int statusLayoutGeneration;

        private boolean combinedBoundsValid;
        private int combinedLeftPos;
        private int combinedTopPos;
        private int combinedScreenWidth;
        private int combinedScreenHeight;
        private int combinedImageWidth;
        private int combinedImageHeight;
        private boolean combinedFullInventory;
        private int combinedVisibleEffectCount;
        private boolean combinedContextActionVisible;
        private boolean combinedCreativeModeActionVisible;
        private int combinedVisibleQuickActions;
        private int combinedVisibleUtilityActions;
        private int combinedStatusLayoutGeneration;

        boolean shouldRebuildStatusLayout(int leftPos,
                                          int topPos,
                                          int imageHeight,
                                          long configRevision) {
            if (statusLayoutValid
                    && statusLeftPos == leftPos
                    && statusTopPos == topPos
                    && statusImageHeight == imageHeight
                    && statusConfigRevision == configRevision) {
                return false;
            }

            statusLayoutValid = true;
            statusLeftPos = leftPos;
            statusTopPos = topPos;
            statusImageHeight = imageHeight;
            statusConfigRevision = configRevision;
            statusLayoutGeneration++;
            combinedBoundsValid = false;
            return true;
        }

        boolean shouldRebuildCombinedBounds(
                int leftPos,
                int topPos,
                int screenWidth,
                int screenHeight,
                int imageWidth,
                int imageHeight,
                boolean fullInventory,
                int visibleEffectCount,
                boolean contextActionVisible,
                boolean creativeModeActionVisible,
                int visibleQuickActions,
                int visibleUtilityActions
        ) {
            if (combinedBoundsValid
                    && combinedLeftPos == leftPos
                    && combinedTopPos == topPos
                    && combinedScreenWidth == screenWidth
                    && combinedScreenHeight == screenHeight
                    && combinedImageWidth == imageWidth
                    && combinedImageHeight == imageHeight
                    && combinedFullInventory == fullInventory
                    && combinedVisibleEffectCount == visibleEffectCount
                    && combinedContextActionVisible == contextActionVisible
                    && combinedCreativeModeActionVisible == creativeModeActionVisible
                    && combinedVisibleQuickActions == visibleQuickActions
                    && combinedVisibleUtilityActions == visibleUtilityActions
                    && combinedStatusLayoutGeneration == statusLayoutGeneration) {
                return false;
            }

            combinedBoundsValid = true;
            combinedLeftPos = leftPos;
            combinedTopPos = topPos;
            combinedScreenWidth = screenWidth;
            combinedScreenHeight = screenHeight;
            combinedImageWidth = imageWidth;
            combinedImageHeight = imageHeight;
            combinedFullInventory = fullInventory;
            combinedVisibleEffectCount = visibleEffectCount;
            combinedContextActionVisible = contextActionVisible;
            combinedCreativeModeActionVisible = creativeModeActionVisible;
            combinedVisibleQuickActions = visibleQuickActions;
            combinedVisibleUtilityActions = visibleUtilityActions;
            combinedStatusLayoutGeneration = statusLayoutGeneration;
            return true;
        }

        void invalidateCombinedBounds() {
            combinedBoundsValid = false;
        }
    }






}
