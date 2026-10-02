package org.questcraft.veq.mixin;

import net.minecraft.client.Minecraft;
import org.questcraft.veq.client.input.HandActionContext;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.Inject;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfo;

// The dedicated handed action is polled directly. It never enters
// Minecraft.startUseItem, so ImmersiveMC cannot consume the logical-left
// trigger through Minecraft's global/right-hand hitResult first.
// Vivecraft's MinecraftVRMixin has priority 1100 and refreshes OpenXR action
// state at tick HEAD. Run immediately after it, but still before vanilla pick
// and handleKeybinds consume the routed target/key state.
@Mixin(value = Minecraft.class, priority = 1000)
public abstract class MinecraftHandActionMixin {
    @Inject(method = "tick", at = @At("HEAD"))
    private void veq$pollLeftTrigger(CallbackInfo callback) {
        HandActionContext.tick((Minecraft) (Object) this);
    }

}
