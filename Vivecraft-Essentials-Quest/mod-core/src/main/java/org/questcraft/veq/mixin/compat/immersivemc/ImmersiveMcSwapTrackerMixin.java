package org.questcraft.veq.mixin.compat.immersivemc;

import net.minecraft.client.KeyMapping;
import net.minecraft.world.InteractionHand;
import org.questcraft.veq.client.input.ImmersiveAttackState;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.Pseudo;
import org.spongepowered.asm.mixin.Unique;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.Inject;
import org.spongepowered.asm.mixin.injection.Redirect;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfo;

/** Optional, fail-open handed attack bridge for ImmersiveMC's drag tracker. */
@Pseudo
@Mixin(
        targets = "com.hammy275.immersivemc.client.immersive.SwapTracker",
        remap = false
)
public abstract class ImmersiveMcSwapTrackerMixin {
    @Unique
    private InteractionHand veq$interactionHand;

    @Inject(
            method = "<init>(Lnet/minecraft/world/InteractionHand;)V",
            at = @At("RETURN"),
            require = 0,
            remap = false
    )
    private void veq$captureInteractionHand(
            InteractionHand hand,
            CallbackInfo callback
    ) {
        this.veq$interactionHand = hand;
    }

    @Redirect(
            method = {
                    "tick(Lcom/hammy275/immersivemc/api/client/immersive/Immersive;" +
                            "Lcom/hammy275/immersivemc/api/client/immersive/ImmersiveInfo;IZ)V",
                    "setState(Lcom/hammy275/immersivemc/client/immersive/" +
                            "SwapTracker$SwapState;I)V"
            },
            at = @At(
                    value = "INVOKE",
                    target = "Lnet/minecraft/client/KeyMapping;isDown()Z"
            ),
            require = 0,
            remap = false
    )
    private boolean veq$resolveHandedAttack(KeyMapping attackKey) {
        return ImmersiveAttackState.resolve(
                this.veq$interactionHand,
                attackKey.isDown()
        );
    }
}
