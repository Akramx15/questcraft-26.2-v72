package org.vivecraft.mixin.client_vr.multiplayer;

import com.llamalad7.mixinextras.injector.wrapmethod.WrapMethod;
import com.llamalad7.mixinextras.injector.wrapoperation.Operation;
import com.llamalad7.mixinextras.injector.wrapoperation.WrapOperation;
import net.minecraft.client.Minecraft;
import net.minecraft.client.multiplayer.MultiPlayerGameMode;
import net.minecraft.client.player.LocalPlayer;
import net.minecraft.core.BlockPos;
import net.minecraft.network.protocol.game.ServerboundUseItemPacket;
import net.minecraft.world.InteractionHand;
import net.minecraft.world.InteractionResult;
import net.minecraft.world.entity.player.Player;
import net.minecraft.world.phys.BlockHitResult;
import org.joml.Vector3fc;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.Unique;
import org.spongepowered.asm.mixin.injection.At;
import org.vivecraft.api.data.VRBodyPart;
import org.vivecraft.client.network.ClientNetworking;
import org.vivecraft.client_vr.ClientDataHolderVR;
import org.vivecraft.client_vr.VRState;
import org.vivecraft.client_vr.gameplay.ClientHandActionTickGuard;
import org.vivecraft.client_vr.gameplay.ScopedUseItemOnContext;

import java.util.function.Supplier;

/**
 * we override the players look direction so the server handles any interactions as if the player looked at the interacted block
 */
@Mixin(MultiPlayerGameMode.class)
public class MultiPlayerGameModeVRMixin {

    @WrapMethod(method = "useItem")
    private InteractionResult vivecraft$useLookOverride(
        Player player, InteractionHand hand, Operation<InteractionResult> original)
    {
        return this.vivecraft$wrapWithLookOverride(() -> original.call(player, hand), player,
            () -> ClientDataHolderVR.getInstance().vrPlayer.getRightClickLookOverride(player, hand.ordinal()));
    }

    @WrapMethod(method = "releaseUsingItem")
    private void vivecraft$releaseUseLookOverride(Player player, Operation<Void> original) {
        this.vivecraft$wrapWithLookOverride(() -> original.call(player), player,
            () -> ClientDataHolderVR.getInstance().vrPlayer.getRightClickLookOverride(player,
                player.getUsedItemHand().ordinal()));
    }

    @WrapMethod(method = "useItemOn")
    private InteractionResult vivecraft$useOnLookOverride(
        LocalPlayer player, InteractionHand hand, BlockHitResult result, Operation<InteractionResult> original)
    {
        return this.vivecraft$wrapWithLookOverride(
            () -> original.call(player, hand, result), player,
            () -> vivecraft$useItemOnLookOverride(player, hand));
    }

    @Unique
    private static Vector3fc vivecraft$useItemOnLookOverride(Player player, InteractionHand hand) {
        ScopedUseItemOnContext.Snapshot translated = ScopedUseItemOnContext.current();
        if (translated != null) {
            return translated.lookDirection(player.getEyePosition(1.0F));
        }
        return ClientDataHolderVR.getInstance().vrPlayer.getRightClickLookOverride(
            player, hand.ordinal());
    }

    @Unique
    private <T> T vivecraft$wrapWithLookOverride(Supplier<T> useCall, Player player, Supplier<Vector3fc> viewSupplier) {
        boolean overridden = VRState.VR_RUNNING;
        if (overridden) {
            ClientNetworking.overrideLook(player, viewSupplier);
        }
        try {
            return useCall.get();
        } finally {
            if (overridden) {
                ClientNetworking.restoreLook();
            }
        }
    }

    @WrapOperation(method = "lambda$useItem$0", at = @At(value = "NEW", target = "net/minecraft/network/protocol/game/ServerboundUseItemPacket"))
    private ServerboundUseItemPacket vivecraft$lookOverridePacket(
        InteractionHand hand, int sequence, float yRot, float xRot, Operation<ServerboundUseItemPacket> original)
    {
        if (VRState.VR_RUNNING) {
            Vector3fc dir = ClientNetworking.getActiveAimDir();
            yRot = (float) Math.toDegrees(Math.atan2(-dir.x(), dir.z()));
            xRot = (float) Math.toDegrees(Math.asin(-dir.y() / dir.length()));
        }
        return original.call(hand, sequence, yRot, xRot);
    }

    @WrapMethod(method = "sameDestroyTarget")
    private boolean vivecraft$dualWieldingSkipItemCheck(BlockPos pos, Operation<Boolean> original) {
        if (VRState.VR_RUNNING && ClientNetworking.SERVER_ALLOWS_DUAL_WIELDING) {
            VRBodyPart previousOverride = ClientNetworking.BODY_PART_CLIENT_OVERRIDE;
            try {
                // A coordinated button session pins its original body part.
                // Respect that scope so the other hand cannot accidentally
                // satisfy Vanilla's destroyingItem check after the owner's
                // tool changes mid-session.
                VRBodyPart coordinatedOwner = null;
                if (!vivecraft$hasPinnedDestroyOwner(previousOverride)) {
                    Minecraft minecraft = Minecraft.getInstance();
                    if (minecraft.level != null) {
                        coordinatedOwner = ClientHandActionTickGuard.global()
                            .pinnedButtonMiningOwner(
                                minecraft.level, minecraft.level.getGameTime(), pos);
                    }
                }
                VRBodyPart destroyOwner = vivecraft$resolvePinnedDestroyOwner(
                    previousOverride, coordinatedOwner);
                if (vivecraft$hasPinnedDestroyOwner(destroyOwner)) {
                    ClientNetworking.BODY_PART_CLIENT_OVERRIDE = destroyOwner;
                    return original.call(pos);
                }

                // Legacy unscoped callers may still match either hand, which
                // preserves Vivecraft's existing dual-wield behavior.
                ClientNetworking.BODY_PART_CLIENT_OVERRIDE = VRBodyPart.MAIN_HAND;
                boolean sameItem = original.call(pos);

                ClientNetworking.BODY_PART_CLIENT_OVERRIDE = VRBodyPart.OFF_HAND;
                sameItem |= original.call(pos);
                return sameItem;
            } finally {
                ClientNetworking.BODY_PART_CLIENT_OVERRIDE = previousOverride;
            }
        } else {
            return original.call(pos);
        }
    }

    @Unique
    private static boolean vivecraft$hasPinnedDestroyOwner(VRBodyPart bodyPartOverride) {
        return bodyPartOverride == VRBodyPart.MAIN_HAND ||
            bodyPartOverride == VRBodyPart.OFF_HAND;
    }

    @Unique
    private static VRBodyPart vivecraft$resolvePinnedDestroyOwner(
        VRBodyPart scopedOwner, VRBodyPart coordinatedOwner)
    {
        if (vivecraft$hasPinnedDestroyOwner(scopedOwner)) {
            return scopedOwner;
        }
        return vivecraft$hasPinnedDestroyOwner(coordinatedOwner)
            ? coordinatedOwner
            : null;
    }
}
