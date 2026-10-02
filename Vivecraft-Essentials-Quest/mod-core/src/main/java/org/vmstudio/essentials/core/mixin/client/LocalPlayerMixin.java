package org.vmstudio.essentials.core.mixin.client;

import net.minecraft.client.player.LocalPlayer;
import org.spongepowered.asm.mixin.Mixin;
import org.vmstudio.essentials.core.client.extensions.LocalPlayerExtension;

@Mixin(LocalPlayer.class)
public abstract class LocalPlayerMixin implements LocalPlayerExtension {

}
