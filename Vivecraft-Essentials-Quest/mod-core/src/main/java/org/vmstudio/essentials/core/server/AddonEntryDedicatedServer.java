package org.vmstudio.essentials.core.server;

import org.vmstudio.essentials.core.common.network.EssentialsChannel;
import org.vmstudio.visor.api.VisorAPI;
import org.vmstudio.visor.api.common.addon.VisorAddon;
import org.vmstudio.essentials.core.common.VisorEssentials;
import net.minecraft.network.chat.Component;
import org.jetbrains.annotations.NotNull;

public class AddonEntryDedicatedServer implements VisorAddon {
    @Override
    public void onAddonRegister() {
        EssentialsChannel.createChannel(this);
    }

    @Override
    public void onAddonLoad() {
        VisorEssentials.SERVER = new EssentialsServer();
        VisorAPI.eventBus().registerListener(this, VisorEssentials.SERVER);
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
