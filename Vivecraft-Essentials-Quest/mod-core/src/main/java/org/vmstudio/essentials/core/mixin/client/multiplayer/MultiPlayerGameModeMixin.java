package org.vmstudio.essentials.core.mixin.client.multiplayer;

import net.minecraft.client.multiplayer.MultiPlayerGameMode;
import net.minecraft.client.player.LocalPlayer;
import net.minecraft.world.InteractionHand;
import net.minecraft.world.InteractionResult;
import net.minecraft.world.entity.Entity;
import net.minecraft.world.entity.player.Player;
import net.minecraft.world.phys.BlockHitResult;
import net.minecraft.world.phys.EntityHitResult;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.Inject;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfoReturnable;
import org.vmstudio.essentials.core.client.gui.NativeContainerPlacement;
import org.vmstudio.essentials.core.common.VisorEssentials;
import org.vmstudio.visor.api.VisorAPI;

/** Captures the real VR interaction target before a server opens its screen. */
@Mixin(MultiPlayerGameMode.class)
public abstract class MultiPlayerGameModeMixin {

    @Inject(method = "useItemOn", at = @At("HEAD"))
    private void visorEssentials$rememberBlockInteraction(
            LocalPlayer player,
            InteractionHand hand,
            BlockHitResult hit,
            CallbackInfoReturnable<InteractionResult> cir) {
        if (VisorEssentials.customInventory
                && VisorAPI.clientState().stateMode().isActive()) {
            NativeContainerPlacement.rememberInteraction(hit);
        }
    }

    @Inject(method = "interact", at = @At("HEAD"))
    private void visorEssentials$rememberEntityInteraction(
            Player player,
            Entity entity,
            EntityHitResult hit,
            InteractionHand hand,
            CallbackInfoReturnable<InteractionResult> cir) {
        if (VisorEssentials.customInventory
                && VisorAPI.clientState().stateMode().isActive()) {
            NativeContainerPlacement.rememberInteraction(hit);
        }
    }

    @Inject(method = "useItem", at = @At("HEAD"))
    private void visorEssentials$forgetPassedTarget(
            Player player,
            InteractionHand hand,
            CallbackInfoReturnable<InteractionResult> cir) {
        NativeContainerPlacement.clearPendingInteraction();
    }
}
