package org.vmstudio.essentials.core.platform;

import dev.architectury.injectables.annotations.ExpectPlatform;
import net.minecraft.world.effect.MobEffectInstance;

/**
 * Loader-specific visibility hook for effects shown beside inventory screens.
 */
public final class ClientEffectHooks {
    private ClientEffectHooks() {}

    @ExpectPlatform
    public static boolean shouldRenderEffect(MobEffectInstance effect) {
        throw new AssertionError();
    }
}
