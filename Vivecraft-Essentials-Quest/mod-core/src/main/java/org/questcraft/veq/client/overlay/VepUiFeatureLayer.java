package org.questcraft.veq.client.overlay;

import net.minecraft.client.Minecraft;
import net.minecraft.client.gui.screens.inventory.CreativeModeInventoryScreen;
import net.minecraft.client.player.LocalPlayer;
import org.jetbrains.annotations.Nullable;
import org.questcraft.veq.client.gui.QuickActionEditorScreen;
import org.questcraft.veq.client.gui.VepCreativeWristScreen;
import org.questcraft.veq.client.gui.VepWristInventoryScreen;

/**
 * Stateful VEP UI feature layer, deliberately independent of world-space
 * rendering. One adapter registers its active content with Vivecraft's
 * multi-surface engine.
 */
public final class VepUiFeatureLayer implements VepWristInventoryScreen.Navigation {
    public static final String INVENTORY_SURFACE_ID = "vep_wrist_inventory";
    public static final String CREATIVE_SURFACE_ID = "vep_creative_inventory";

    private final Minecraft minecraft = Minecraft.getInstance();
    private @Nullable VepScreenContent activeContent;
    private @Nullable VepWristInventoryScreen inventory;
    private @Nullable VepCreativeWristScreen creative;
    private @Nullable VepContextualContainerContent contextualContainer;
    private int scaledWidth;
    private int scaledHeight;

    public void initialize(int scaledWidth, int scaledHeight) {
        this.scaledWidth = Math.max(1, scaledWidth);
        this.scaledHeight = Math.max(1, scaledHeight);
        LocalPlayer player = minecraft.player;
        if (player == null) {
            hardClose();
            return;
        }
        boolean inventoryChanged = inventory == null || inventory.menu() != player.inventoryMenu;
        if (inventoryChanged) {
            if (activeContent != null) {
                activeContent.hardClose();
            }
            inventory = new VepWristInventoryScreen(player, this);
            creative = null;
            activeContent = null;
        }
        if (activeContent == null) {
            setActive(inventory);
        } else {
            initializeContent(activeContent);
        }
    }

    public @Nullable VepScreenContent activeContent() {
        return activeContent;
    }

    public @Nullable VepContextualContainerContent contextualContainer() {
        return contextualContainer;
    }

    public boolean isInitialized() {
        return activeContent != null;
    }

    public void tick() {
        VepScreenContent content = activeContent;
        if (content != null) {
            content.tick();
        }
    }

    public void showContextualContainer(@Nullable VepContextualContainerContent container) {
        // Contextual containers retain Minecraft's real Screen ownership and
        // are rendered by their own claimed-global-screen surface. Never put
        // that Screen through the 360x240 wrist initialization path.
        contextualContainer = container;
    }

    public void clearContextualContainer(boolean closeNativeScreen) {
        VepContextualContainerContent old = contextualContainer;
        contextualContainer = null;
        if (closeNativeScreen && old != null) {
            old.hardClose();
        }
    }

    @Override
    public void openCreative(VepWristInventoryScreen source) {
        LocalPlayer player = minecraft.player;
        if (player == null
                || minecraft.gameMode == null
                || !minecraft.gameMode.getPlayerMode().isCreative()
                || player.connection == null
                || source != inventory
                || activeContent != source
                || !source.menu().getCarried().isEmpty()) {
            return;
        }
        VepCreativeWristScreen next = new VepCreativeWristScreen(
                player,
                player.connection.enabledFeatures(),
                minecraft.options.operatorItemsTab().get(),
                this::popOutCreativeMenu,
                this::backToInventory
        );
        creative = next;
        setActive(next);
    }

    @Override
    public void editQuickAction(int slot, VepWristInventoryScreen source) {
        // The editor is intentionally an ordinary head-mounted screen. The
        // wrist surfaces soft-hide while it is open and return afterwards.
        QuickActionEditorScreen.open(slot, null);
    }

    public void backToInventory() {
        LocalPlayer player = minecraft.player;
        VepCreativeWristScreen oldCreative = creative;
        if (oldCreative != null) {
            creative = null;
            oldCreative.hardClose();
        }
        if (player == null) {
            hardClose();
            return;
        }
        if (inventory == null || inventory.menu() != player.inventoryMenu) {
            inventory = new VepWristInventoryScreen(player, this);
        }
        setActive(inventory);
    }

    /** Explicit VEP pop-out control; ordinary wrist activation never calls setScreen. */
    private void popOutCreativeMenu() {
        VepCreativeWristScreen oldCreative = creative;
        LocalPlayer player = minecraft.player;
        if (oldCreative == null || player == null || player.connection == null
                || activeContent != oldCreative || !oldCreative.getMenu().getCarried().isEmpty()) {
            return;
        }
        creative = null;
        activeContent = null;
        oldCreative.hardClose();
        minecraft.gui.setScreen(new CreativeModeInventoryScreen(
                player,
                player.connection.enabledFeatures(),
                minecraft.options.operatorItemsTab().get()
        ));
    }

    public void hardClose() {
        VepScreenContent old = activeContent;
        activeContent = null;
        if (old != null) {
            old.hardClose();
        }
        inventory = null;
        creative = null;
    }

    private void setActive(VepScreenContent content) {
        activeContent = content;
        initializeContent(content);
    }

    private void initializeContent(VepScreenContent content) {
        content.screen().init(scaledWidth, scaledHeight);
        if (content instanceof VepCreativeWristScreen creativeScreen) {
            creativeScreen.removeInjectedWidgets();
        }
    }
}
