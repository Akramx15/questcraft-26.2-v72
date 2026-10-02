package org.vmstudio.essentials.core.platform.fabric;

import net.minecraft.world.effect.MobEffectInstance;

/** Fabric uses Minecraft's standard inventory-effect visibility rules. */
public final class ClientEffectHooksImpl {
    private ClientEffectHooksImpl() {
    }

    public static boolean shouldRenderEffect(MobEffectInstance effect) {
        return true;
    }
}