package org.vmstudio.essentials.core.common.network;

import net.minecraft.resources.Identifier;
import net.minecraft.util.Mth;
import org.jetbrains.annotations.NotNull;
import org.vmstudio.essentials.core.common.VisorEssentials;
import org.vmstudio.essentials.core.common.network.toserver.BowTensionPayloadToServer;
import org.vmstudio.visor.api.common.addon.VisorAddon;
import org.vmstudio.visor.api.common.network.VisorChannel;
import org.vmstudio.visor.api.common.network.VisorNetwork;

public final class EssentialsChannel {

    public static final Identifier ID =
            Identifier.fromNamespaceAndPath(VisorEssentials.MOD_ID, "channel");
    public static final int NETWORK_VERSION = 1;

    private static VisorChannel INSTANCE;

    private EssentialsChannel() {}

    public static @NotNull VisorChannel get() {
        if (INSTANCE == null) {
            throw new IllegalStateException(
                    "EssentialsChannel not built — call createChannel(owner) during addon registration");
        }
        return INSTANCE;
    }

    public static void createChannel(@NotNull VisorAddon owner) {
        if (INSTANCE != null) return;
        INSTANCE = VisorChannel.builder(owner, ID, NETWORK_VERSION)
                .toServer(
                        (id, buffer)-> BowTensionPayloadToServer.read(buffer),
                        (payload, sender, response) -> {
                            float tension = payload.tension();
                            if (!Float.isFinite(tension)) {
                                return;
                            }
                            var server = VisorEssentials.SERVER;
                            if (server == null) {
                                return;
                            }
                            var essentialsPlayer = server.getPlayer(sender.getUUID());
                            if(essentialsPlayer == null) return;

                            essentialsPlayer.setBowTension(
                                    Mth.clamp(tension, 0.0F, 1.0F)
                            );
                        }
                )
                .build();
        VisorNetwork.registerChannel(INSTANCE);
    }
}
