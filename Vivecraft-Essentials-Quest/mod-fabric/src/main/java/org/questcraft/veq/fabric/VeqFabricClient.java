package org.questcraft.veq.fabric;

import com.mojang.blaze3d.platform.InputConstants;
import net.fabricmc.api.ClientModInitializer;
import net.fabricmc.fabric.api.client.event.lifecycle.v1.ClientTickEvents;
import net.fabricmc.fabric.api.client.keymapping.v1.KeyMappingHelper;
import net.minecraft.client.KeyMapping;
import net.minecraft.network.chat.Component;
import net.minecraft.resources.Identifier;
import org.questcraft.veq.VivecraftEssentialsQuest;
import org.questcraft.veq.client.config.GripHotbarConfig;
import org.questcraft.veq.client.config.QuestButtonBindingsConfig;
import org.questcraft.veq.client.config.WristUiConfig;
import org.questcraft.veq.client.config.VepFeatureConfig;
import org.questcraft.veq.client.compat.VepUtilityActionRegistry;
import org.questcraft.veq.client.gui.WristSettingsScreen;
import org.questcraft.veq.client.overlay.VepMultiSurfaceAdapter;
import org.questcraft.veq.client.overlay.WristOverlayHandler;
import org.questcraft.veq.client.radial.RadialHotbarController;
import org.questcraft.veq.client.quickactions.QuickActionManager;
import org.questcraft.veq.client.input.QuestButtonKeyMappings;
import org.questcraft.veq.client.wrist.WristInventoryTracker;
import org.vivecraft.api.client.VRClientAPI;
import org.vivecraft.client_vr.provider.HandedKeyBinding;

public final class VeqFabricClient implements ClientModInitializer {
    private static final KeyMapping.Category CATEGORY = KeyMapping.Category.register(
            Identifier.fromNamespaceAndPath(VivecraftEssentialsQuest.MOD_ID, "controls")
    );

    @Override
    public void onInitializeClient() {
        WristUiConfig.getInstance();
        GripHotbarConfig.getInstance();
        QuestButtonBindingsConfig.getInstance();
        VepFeatureConfig.getInstance();
        QuickActionManager.getInstance();
        VepUtilityActionRegistry.getInstance().discoverOptionalActions();
        VepMultiSurfaceAdapter.install();
        RadialHotbarController.install();
        WristInventoryTracker wristTracker = new WristInventoryTracker();
        VRClientAPI.instance().addClientRegistrationHandler(event -> event.registerTrackers(wristTracker));

        KeyMapping settings = KeyMappingHelper.registerKeyMapping(new KeyMapping(
                "key.vivecraft_essentials_quest.settings",
                InputConstants.Type.KEYSYM,
                InputConstants.UNKNOWN.getValue(),
                CATEGORY
        ));
        KeyMapping toggleWrist = KeyMappingHelper.registerKeyMapping(new KeyMapping(
                "key.vivecraft_essentials_quest.toggle_wrist",
                InputConstants.Type.KEYSYM,
                InputConstants.UNKNOWN.getValue(),
                CATEGORY
        ));
        HandedKeyBinding attackBreakThisHandButton = new HandedKeyBinding(
                QuestButtonKeyMappings.ATTACK_BREAK_THIS_HAND_BUTTON_NAME,
                InputConstants.UNKNOWN.getValue(),
                CATEGORY
        );
        KeyMappingHelper.registerKeyMapping(attackBreakThisHandButton);
        QuestButtonKeyMappings.registerAttackBreakThisHandButton(attackBreakThisHandButton);

        ClientTickEvents.END_CLIENT_TICK.register(minecraft -> {
            QuickActionManager.getInstance().tick();
            VepUtilityActionRegistry.getInstance().refreshOptionalActionsIfNeeded();
            RadialHotbarController.tick();
            VepMultiSurfaceAdapter.tickContextualContainer();
            WristOverlayHandler.tickManualVisibility(
                    minecraft.player != null && WristUiConfig.getInstance().enabled()
            );
            while (settings.consumeClick()) {
                minecraft.gui.setScreen(new WristSettingsScreen(minecraft.gui.screen()));
            }
            while (toggleWrist.consumeClick()) {
                WristOverlayHandler.toggleManualVisibility(
                        minecraft.player != null && WristUiConfig.getInstance().enabled()
                );
            }
        });
        VivecraftEssentialsQuest.LOGGER.info("Loaded Vivecraft Essentials Quest for Minecraft 26.2");
    }
}
