package org.questcraft.veq.client.input;

import net.minecraft.client.Minecraft;
import net.minecraft.client.player.LocalPlayer;
import net.minecraft.world.InteractionHand;
import net.minecraft.world.entity.Entity;
import net.minecraft.world.entity.projectile.ProjectileUtil;
import net.minecraft.world.item.ItemStack;
import net.minecraft.world.level.ClipContext;
import net.minecraft.world.phys.AABB;
import net.minecraft.world.phys.BlockHitResult;
import net.minecraft.world.phys.EntityHitResult;
import net.minecraft.world.phys.HitResult;
import net.minecraft.world.phys.Vec3;
import org.joml.Vector3f;
import org.vivecraft.client_vr.VRData;
import org.vivecraft.client_vr.provider.ControllerType;

/** One immutable controller-ray result; it never mutates Minecraft's global target. */
record HandTargetSnapshot(
        ControllerType controller,
        InteractionHand hand,
        Vec3 start,
        Vec3 direction,
        BlockHitResult blockHit,
        EntityHitResult entityHit,
        HitResult primaryHit
) {
    static HandTargetSnapshot capture(
            Minecraft minecraft,
            LocalPlayer player,
            HandOwnershipSnapshot.HandState state,
            InteractionHand hand,
            boolean itemAwareFluids
    ) {
        return capture(
                minecraft, player, state.controller(), state.aimPose(), hand,
                itemAwareFluids);
    }

    /**
     * Render-time overload used by visual pointers. Gameplay routing keeps the
     * tick pose overload above, while visual state can use the latest OpenXR
     * render pose without manufacturing another HandState record.
     */
    static HandTargetSnapshot capture(
            Minecraft minecraft,
            LocalPlayer player,
            ControllerType controller,
            VRData.VRDevicePose pose,
            InteractionHand hand,
            boolean itemAwareFluids
    ) {
        Vec3 start = pose.getPosition();
        Vector3f directionF = pose.getDirection().normalize();
        Vec3 direction = new Vec3(directionF.x, directionF.y, directionF.z);

        ItemStack stack = player.getItemInHand(hand);
        ClipContext.Fluid fluid = itemAwareFluids
                ? HandRaycastFluidPolicy.forUse(stack)
                : ClipContext.Fluid.NONE;
        double blockReach = player.blockInteractionRange();
        Vec3 blockEnd = start.add(direction.scale(blockReach));
        BlockHitResult blockHit = minecraft.level.clip(new ClipContext(
                start, blockEnd, ClipContext.Block.OUTLINE, fluid, player));

        double entityReach = player.entityInteractionRange();
        Vec3 entityEnd = start.add(direction.scale(entityReach));
        EntityHitResult entityHit = ProjectileUtil.getEntityHitResult(
                player,
                start,
                entityEnd,
                raySearchBounds(start, entityEnd),
                entity -> isPickableEntity(player, entity),
                entityReach * entityReach
        );
        HitResult primary = nearerEntity(start, blockHit, entityHit) ? entityHit : blockHit;
        return new HandTargetSnapshot(
                controller, hand, start, direction, blockHit, entityHit, primary);
    }

    static AABB raySearchBounds(Vec3 start, Vec3 end) {
        return new AABB(start, end).inflate(1.0D);
    }

    private static boolean nearerEntity(
            Vec3 start,
            BlockHitResult blockHit,
            EntityHitResult entityHit
    ) {
        return entityHit != null && entityPrecedesBlock(
                blockHit.getType() == HitResult.Type.BLOCK,
                start.distanceToSqr(entityHit.getLocation()),
                start.distanceToSqr(blockHit.getLocation()));
    }

    static boolean entityPrecedesBlock(
            boolean blockTarget,
            double entityDistanceSquared,
            double blockDistanceSquared
    ) {
        return !blockTarget || entityDistanceSquared < blockDistanceSquared;
    }

    private static boolean isPickableEntity(LocalPlayer player, Entity entity) {
        return entity != player.getVehicle() && !entity.isSpectator() && entity.isPickable();
    }
}
