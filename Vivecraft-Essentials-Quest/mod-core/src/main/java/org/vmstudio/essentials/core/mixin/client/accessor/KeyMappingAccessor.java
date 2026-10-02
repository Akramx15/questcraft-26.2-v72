package org.vmstudio.essentials.core.mixin.client.accessor;

import net.minecraft.client.KeyMapping;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.gen.Accessor;

/** Lets quick actions activate one exact mapping even when physical keys conflict. */
@Mixin(KeyMapping.class)
public interface KeyMappingAccessor {
    @Accessor("clickCount")
    int visorEssentials$getClickCount();

    @Accessor("clickCount")
    void visorEssentials$setClickCount(int clickCount);
}
