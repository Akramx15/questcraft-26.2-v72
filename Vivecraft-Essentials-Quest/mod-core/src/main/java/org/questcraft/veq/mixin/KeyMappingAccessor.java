package org.questcraft.veq.mixin;

import net.minecraft.client.KeyMapping;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.gen.Accessor;

@Mixin(KeyMapping.class)
public interface KeyMappingAccessor {
    @Accessor("clickCount")
    int veq$getClickCount();

    @Accessor("clickCount")
    void veq$setClickCount(int value);
}
