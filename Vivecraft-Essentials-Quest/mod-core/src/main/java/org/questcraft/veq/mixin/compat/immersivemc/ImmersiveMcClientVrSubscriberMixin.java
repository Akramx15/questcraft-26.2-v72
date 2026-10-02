package org.questcraft.veq.mixin.compat.immersivemc;

import net.minecraft.client.KeyMapping;
import net.minecraft.world.InteractionHand;
import org.questcraft.veq.client.input.ImmersiveAttackState;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.Pseudo;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.Coerce;
import org.spongepowered.asm.mixin.injection.Redirect;

/**
 * Supplies ImmersiveMC's VR hitbox path with VEQ's handed attack state.
 *
 * <p>The full descriptor pins this optional bridge to the official
 * 1.6.0-alpha4.1 Vivecraft ABI. A missing mod, changed ABI, or changed key read
 * leaves ImmersiveMC's original value untouched instead of making VEQ a hard
 * dependency or preventing startup.</p>
 */
@Pseudo
@Mixin(
        targets = "com.hammy275.immersivemc.client.subscribe.ClientVRSubscriber",
        remap = false
)
public abstract class ImmersiveMcClientVrSubscriberMixin {
    @Redirect(
            method = "handleInfos(Lcom/hammy275/immersivemc/api/client/immersive/Immersive;" +
                    "Lorg/vivecraft/api/data/VRPose;" +
                    "Lnet/minecraft/world/InteractionHand;)Z",
            at = @At(
                    value = "INVOKE",
                    target = "Lnet/minecraft/client/KeyMapping;isDown()Z"
            ),
            require = 0,
            remap = false
    )
    private static boolean veq$resolveHandedAttack(
            KeyMapping attackKey,
            @Coerce Object immersive,
            @Coerce Object vrPose,
            InteractionHand hand
    ) {
        return ImmersiveAttackState.resolve(hand, attackKey.isDown());
    }
}
