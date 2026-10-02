package org.vivecraft.mixin.client_vr.multiplayer;

import net.minecraft.client.multiplayer.MultiPlayerGameMode;
import net.minecraft.core.BlockPos;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.gen.Accessor;

/** Read-only access to Vanilla's single active destroy target. */
@Mixin(MultiPlayerGameMode.class)
public interface MultiPlayerGameModeAccessor {
    @Accessor("destroyBlockPos")
    BlockPos vivecraft$getDestroyBlockPos();
}
