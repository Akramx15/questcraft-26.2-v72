package org.questcraft.veq.client.input;

import net.minecraft.client.Minecraft;
import org.vivecraft.client_vr.settings.VRSettings;

/** Stable mixin entry point; all hand policy lives in the router. */
public final class HandActionContext {
    private static final PerHandWorldActionRouter ROUTER = new PerHandWorldActionRouter();

    private HandActionContext() {
    }

    public static void tick(Minecraft minecraft) {
        ROUTER.tick(minecraft);
    }

    static int useDelay(VRSettings.RightClickDelay delay) {
        return PerHandWorldActionRouter.useDelay(delay);
    }

    public static void clearForVrShutdown() {
        ROUTER.clearForVrShutdown(Minecraft.getInstance());
    }
}
