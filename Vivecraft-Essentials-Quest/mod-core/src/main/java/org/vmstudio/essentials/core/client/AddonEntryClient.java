package org.vmstudio.essentials.core.client;

import net.minecraft.client.Minecraft;
import net.minecraft.client.gui.screens.Screen;
import net.minecraft.network.chat.Component;
import org.jetbrains.annotations.NotNull;
import org.jetbrains.annotations.Nullable;
import org.vmstudio.essentials.core.client.gui.overlays.VROverlayContainer;
import org.vmstudio.essentials.core.client.gui.overlays.VROverlayDraggedItem;
import org.vmstudio.essentials.core.client.gui.overlays.VROverlayInventory;
import org.vmstudio.essentials.core.client.gui.screens.VisorEssentialsSettingsScreen;
import org.vmstudio.essentials.core.client.config.WristUiConfig;
import org.vmstudio.essentials.core.client.render.RemoteOverlayRenderHelper;
import org.vmstudio.essentials.core.common.VisorEssentials;
import org.vmstudio.essentials.core.common.network.EssentialsChannel;
import org.vmstudio.essentials.core.server.EssentialsServer;
import org.vmstudio.visor.api.VisorAPI;
import org.vmstudio.visor.api.common.addon.VisorAddon;

import java.util.List;

public class AddonEntryClient implements VisorAddon {
    public static Minecraft MC;

    @Override
    public void onAddonRegister() {
        EssentialsChannel.createChannel(this);
    }

    @Override
    public void onAddonLoad() {
        MC = Minecraft.getInstance();
        // Load once with the addon so defaults are written before the wrist
        // inventory or settings page is opened for the first time.
        WristUiConfig.getInstance();

        VROverlayInventory inventoryOverlay =
                new VROverlayInventory(this, VROverlayInventory.ID);
        VisorAPI.addonManager().getRegistries().overlays()
                .registerComponents(List.of(
                        new VROverlayDraggedItem(this, VROverlayDraggedItem.ID),
                        new VROverlayContainer(this, VROverlayContainer.ID),
                        inventoryOverlay
                ));

        VisorEssentials.SERVER = new EssentialsServer();
        VisorAPI.eventBus().registerListener(this, VisorEssentials.SERVER);
        new RemoteOverlayRenderHelper(this);
    }

    @Override
    public @Nullable String getAddonPackagePath() {
        return "org.vmstudio.essentials.core.client";
    }

    @Override
    public @NotNull Screen createAddonSettingsScreen(@NotNull Screen backScreen) {
        return new VisorEssentialsSettingsScreen(backScreen);
    }

    @Override
    public @NotNull String getAddonId() {
        return VisorEssentials.MOD_ID;
    }

    @Override
    public @NotNull Component getAddonName() {
        return Component.literal(VisorEssentials.MOD_NAME);
    }

    @Override
    public String getModId() {
        return VisorEssentials.MOD_ID;
    }
}
