package org.vivecraft.mixin.world.entity;

import com.llamalad7.mixinextras.injector.wrapoperation.Operation;
import com.llamalad7.mixinextras.injector.wrapoperation.WrapOperation;
import com.llamalad7.mixinextras.injector.wrapmethod.WrapMethod;
import net.minecraft.core.particles.ParticleOptions;
import net.minecraft.server.level.ServerLevel;
import net.minecraft.server.level.ServerPlayer;
import net.minecraft.world.entity.Entity;
import net.minecraft.world.entity.EntityType;
import net.minecraft.world.entity.EquipmentSlot;
import net.minecraft.world.entity.ai.attributes.AttributeInstance;
import net.minecraft.world.entity.ai.attributes.Attributes;
import net.minecraft.world.entity.player.Inventory;
import net.minecraft.world.entity.player.Player;
import net.minecraft.world.inventory.InventoryMenu;
import net.minecraft.world.item.ItemCooldowns;
import net.minecraft.world.item.ItemStack;
import net.minecraft.world.level.Level;
import org.vivecraft.api.data.VRBodyPart;
import org.vivecraft.client.network.ClientNetworking;
import org.vivecraft.client_vr.VRState;
import org.vivecraft.common.network.IndependentAttackStrengthState;
import org.vivecraft.common.network.IndependentHandCooldownPolicy;
import org.vivecraft.common.network.NetworkVersion;
import org.vivecraft.common.network.OffhandAttackSpeedAttributes;
import org.spongepowered.asm.mixin.Final;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.Shadow;
import org.spongepowered.asm.mixin.Unique;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.Inject;
import org.spongepowered.asm.mixin.injection.ModifyArg;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfo;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfoReturnable;
import org.vivecraft.mixin.server.ServerPlayerMixin;
import org.vivecraft.server.ServerVRPlayers;
import org.vivecraft.server.ServerVivePlayer;
import org.vivecraft.server.PairedStrikeHurtContext;
import org.vivecraft.server.config.ServerConfig;

@Mixin(Player.class)
public abstract class PlayerMixin extends LivingEntityMixin {

    @Unique
    private final IndependentAttackStrengthState vivecraft$offhandAttackStrength =
        new IndependentAttackStrengthState();

    @Unique
    private ItemStack vivecraft$lastItemInOffhand = ItemStack.EMPTY;

    /**
     * A detached copy of the local player's attack-speed attribute.  The
     * client keeps MAINHAND's equipment modifiers installed even while it is
     * previewing OFF_HAND combat, so changing only Inventory#getSelectedItem
     * is not enough for axes with different attack speeds.  Reusing one
     * detached instance keeps the live AttributeMap untouched and avoids a
     * per-frame allocation.
     */
    @Unique
    private AttributeInstance vivecraft$offhandAttackSpeedScratch;

    @Unique
    private float vivecraft$offhandAttackStrengthDelay = 5.0F;

    @Unique
    private boolean vivecraft$offhandAttackStrengthDelayValid;

    @Unique
    private int vivecraft$offhandAttackStrengthInventoryVersion = Integer.MIN_VALUE;

    @Unique
    private int vivecraft$offhandAttackStrengthSelectedSlot = Integer.MIN_VALUE;

    @Unique
    private long vivecraft$mainAttackSpeedBits = Long.MIN_VALUE;

    @Shadow
    public abstract Inventory getInventory();

    @Shadow
    @Final
    public InventoryMenu inventoryMenu;

    @Shadow
    public abstract ItemCooldowns getCooldowns();

    @Shadow
    public abstract float getCurrentItemAttackStrengthDelay();

    public PlayerMixin(EntityType<?> entityType, Level level) {
        super(entityType, level);
    }

    /**
     * dummy to be overridden in {@link ServerPlayerMixin}
     */
    @WrapOperation(method = "doSweepAttack*", at = @At(value = "INVOKE", target = "Lnet/minecraft/server/level/ServerLevel;sendParticles(Lnet/minecraft/core/particles/ParticleOptions;DDDIDDDD)I"))
    protected int vivecraft$modifySweepParticleSpawnPos(
        ServerLevel instance, ParticleOptions type, double posX, double posY, double posZ, int particleCount,
        double xOffset, double yOffset, double zOffset, double speed, Operation<Integer> original)
    {
        return original.call(instance, type, posX, posY, posZ, particleCount, xOffset, yOffset, zOffset, speed);
    }

    /**
     * dummy to be overridden in {@link ServerPlayerMixin}
     */
    @ModifyArg(method = "attack", at = @At(value = "INVOKE", target = "Lnet/minecraft/world/entity/Entity;hurtOrSimulate(Lnet/minecraft/world/damagesource/DamageSource;F)Z"))
    protected float vivecraft$damageModifier(float damage) {
        return damage;
    }

    @Inject(method = "attack", at = @At("HEAD"), cancellable = true)
    private void vivecraft$noAttackWhileBlocking(Entity target, CallbackInfo ci) {
        if ((Object) this instanceof ServerPlayer serverPlayer) {
            ServerVivePlayer vivePlayer = ServerVRPlayers.getVivePlayer(serverPlayer);
            if (!ServerConfig.ALLOW_ATTACKS_WHILE_BLOCKING.get() && vivePlayer != null && vivePlayer.isVR() &&
                this.isBlocking())
            {
                ci.cancel();
            }
        }
    }

    @Inject(method = "tick", at = @At("TAIL"))
    private void vivecraft$tickIndependentOffhandAttackStrength(CallbackInfo ci) {
        boolean newlyEnabled = vivecraft$updateIndependentCooldownNegotiation();
        if (!this.vivecraft$offhandAttackStrength.enabled()) {
            this.vivecraft$offhandAttackStrengthDelayValid = false;
            return;
        }

        ItemStack offhand = this.getItemBySlot(net.minecraft.world.entity.EquipmentSlot.OFFHAND);
        if (newlyEnabled) {
            this.vivecraft$lastItemInOffhand = offhand.copy();
            return;
        }

        boolean stackChanged = !ItemStack.matches(this.vivecraft$lastItemInOffhand, offhand);
        boolean itemTypeChanged = stackChanged &&
            !ItemStack.isSameItem(this.vivecraft$lastItemInOffhand, offhand);
        this.vivecraft$offhandAttackStrength.tick(itemTypeChanged);
        if (stackChanged) {
            this.vivecraft$lastItemInOffhand = offhand.copy();
            this.vivecraft$offhandAttackStrengthDelayValid = false;
        }

        Player self = (Player) (Object) this;
        if (!(self instanceof ServerPlayer)) {
            this.vivecraft$refreshOffhandAttackStrengthDelay(self);
        }
    }

    /**
     * Keeps both strikes on the normal Player.attack path. Only the matching
     * follow-up attack receives a one-call hurt-immunity exception, while the
     * successful result and post-durability item state arm the next window.
     */
    @WrapMethod(method = "attack")
    private void vivecraft$pairedStrike(Entity target, Operation<Void> original) {
        if (!((Object) this instanceof ServerPlayer serverPlayer) ||
            !(target instanceof net.minecraft.world.entity.LivingEntity livingTarget))
        {
            original.call(target);
            return;
        }

        ServerVivePlayer vivePlayer = ServerVRPlayers.getVivePlayer(serverPlayer);
        if (vivePlayer == null || !vivePlayer.pairedStrikeEnabledFor(target)) {
            if (vivePlayer != null) {
                vivePlayer.clearPairedStrike();
            }
            original.call(target);
            return;
        }

        VRBodyPart hand = vivePlayer.getActiveItemBodyPart();
        if (hand != VRBodyPart.MAIN_HAND && hand != VRBodyPart.OFF_HAND) {
            vivePlayer.clearPairedStrike();
            original.call(target);
            return;
        }

        int selectedMainSlot = serverPlayer.getInventory().getSelectedSlot();
        ItemStack itemBefore = vivecraft$physicalAttackItem(serverPlayer, hand, selectedMainSlot).copy();
        long tick = serverPlayer.level().getServer().getTickCount();
        float charge = serverPlayer.getAttackStrengthScale(0.5F);
        boolean bypass = vivePlayer.shouldBypassPairedStrike(target, hand, tick, charge);

        if (!PairedStrikeHurtContext.begin(serverPlayer, livingTarget, bypass)) {
            original.call(target);
            return;
        }

        try {
            original.call(target);
            if (PairedStrikeHurtContext.hurtSucceeded()) {
                if (bypass) {
                    // A pair is exactly two successful strikes. Do not let the
                    // follow-up become the start of an unbounded alternating chain.
                    vivePlayer.clearPairedStrike();
                    return;
                }
                int currentMainSlot = serverPlayer.getInventory().getSelectedSlot();
                ItemStack itemAfter = vivecraft$physicalAttackItem(serverPlayer, hand, currentMainSlot);
                if (currentMainSlot != selectedMainSlot ||
                    (!itemBefore.isEmpty() &&
                        (itemAfter.isEmpty() || !ItemStack.isSameItem(itemBefore, itemAfter))))
                {
                    vivePlayer.clearPairedStrike();
                } else {
                    vivePlayer.recordSuccessfulPairedStrike(
                        target, hand, tick, charge, itemAfter, currentMainSlot);
                }
            }
        } finally {
            PairedStrikeHurtContext.end();
        }
    }

    @Unique
    private static ItemStack vivecraft$physicalAttackItem(
        ServerPlayer player, VRBodyPart hand, int selectedMainSlot)
    {
        return hand == VRBodyPart.OFF_HAND ? player.getOffhandItem() :
            player.getInventory().getItem(selectedMainSlot);
    }

    @Inject(method = "getCurrentItemAttackStrengthDelay", at = @At("HEAD"), cancellable = true)
    private void vivecraft$getOffhandAttackStrengthDelay(CallbackInfoReturnable<Float> cir) {
        if (vivecraft$usesIndependentOffhandClock() && !((Object) this instanceof ServerPlayer)) {
            Player self = (Player) (Object) this;
            this.vivecraft$refreshOffhandAttackStrengthDelay(self);
            cir.setReturnValue(this.vivecraft$offhandAttackStrengthDelay);
        }
    }

    @Inject(method = "cannotAttackWithItem", at = @At("HEAD"), cancellable = true)
    private void vivecraft$offhandMinimumAttackCharge(
        ItemStack itemStack, int tolerance, CallbackInfoReturnable<Boolean> cir)
    {
        if (vivecraft$usesIndependentOffhandClock()) {
            cir.setReturnValue(this.vivecraft$offhandAttackStrength.cannotAttack(
                itemStack.getOrDefault(net.minecraft.core.component.DataComponents.MINIMUM_ATTACK_CHARGE, 0.0F),
                tolerance,
                this.getCurrentItemAttackStrengthDelay()));
        }
    }

    @Inject(method = "getAttackStrengthScale", at = @At("HEAD"), cancellable = true)
    private void vivecraft$getOffhandAttackStrengthScale(
        float partialTick, CallbackInfoReturnable<Float> cir)
    {
        if (vivecraft$usesIndependentOffhandClock()) {
            cir.setReturnValue(this.vivecraft$offhandAttackStrength.attackStrengthScale(
                partialTick, this.getCurrentItemAttackStrengthDelay()));
        }
    }

    @Inject(method = "getItemSwapScale", at = @At("HEAD"), cancellable = true)
    private void vivecraft$getOffhandItemSwapScale(
        float partialTick, CallbackInfoReturnable<Float> cir)
    {
        if (vivecraft$usesIndependentOffhandClock()) {
            cir.setReturnValue(this.vivecraft$offhandAttackStrength.itemSwapScale(
                partialTick, this.getCurrentItemAttackStrengthDelay()));
        }
    }

    @Inject(method = "resetAttackStrengthTicker", at = @At("HEAD"), cancellable = true)
    private void vivecraft$resetOffhandAttackAndSwap(CallbackInfo ci) {
        if (vivecraft$usesIndependentOffhandClock()) {
            this.vivecraft$offhandAttackStrength.resetAttackAndSwap();
            ci.cancel();
        }
    }

    @Inject(method = "resetOnlyAttackStrengthTicker", at = @At("HEAD"), cancellable = true)
    private void vivecraft$resetOnlyOffhandAttack(CallbackInfo ci) {
        if (vivecraft$usesIndependentOffhandClock()) {
            this.vivecraft$offhandAttackStrength.resetAttackOnly();
            ci.cancel();
        }
    }

    /** Synchronizes feature lifetime and reports only a fresh activation. */
    @Unique
    private boolean vivecraft$updateIndependentCooldownNegotiation() {
        Player self = (Player) (Object) this;
        boolean negotiated;
        if (self instanceof ServerPlayer serverPlayer) {
            ServerVivePlayer vivePlayer = ServerVRPlayers.getVivePlayer(serverPlayer);
            negotiated = vivePlayer != null && vivePlayer.isVR() &&
                IndependentHandCooldownPolicy.negotiated(
                    ServerConfig.DUAL_WIELDING.get(), vivePlayer.networkVersion);
        } else {
            negotiated = self.isLocalPlayer() && VRState.VR_RUNNING &&
                IndependentHandCooldownPolicy.negotiated(
                    ClientNetworking.SERVER_ALLOWS_DUAL_WIELDING,
                    ClientNetworking.USED_NETWORK_VERSION);
        }

        boolean newlyEnabled = this.vivecraft$offhandAttackStrength.setEnabled(negotiated);
        if (!negotiated) {
            this.vivecraft$lastItemInOffhand = ItemStack.EMPTY;
            this.vivecraft$offhandAttackStrengthDelayValid = false;
        } else if (newlyEnabled) {
            this.vivecraft$lastItemInOffhand =
                this.getItemBySlot(net.minecraft.world.entity.EquipmentSlot.OFFHAND).copy();
            this.vivecraft$offhandAttackStrengthDelayValid = false;
        }
        return newlyEnabled;
    }

    /**
     * Recomputes OFF_HAND's attack delay only when inventory equipment or the
     * live MAINHAND attack-speed value changes.  The scratch instance starts
     * with every non-item modifier from the live player, then mirrors
     * LivingEntity's MAINHAND modifier replacement using the offhand stack.
     */
    @Unique
    private void vivecraft$refreshOffhandAttackStrengthDelay(Player self) {
        Inventory inventory = self.getInventory();
        AttributeInstance liveAttackSpeed = self.getAttribute(Attributes.ATTACK_SPEED);
        if (liveAttackSpeed == null) {
            this.vivecraft$offhandAttackStrengthDelay = 5.0F;
            this.vivecraft$offhandAttackStrengthDelayValid = true;
            return;
        }

        int inventoryVersion = inventory.getTimesChanged();
        int selectedSlot = inventory.getSelectedSlot();
        long attackSpeedBits = Double.doubleToLongBits(liveAttackSpeed.getValue());
        if (this.vivecraft$offhandAttackStrengthDelayValid &&
            this.vivecraft$offhandAttackStrengthInventoryVersion == inventoryVersion &&
            this.vivecraft$offhandAttackStrengthSelectedSlot == selectedSlot &&
            this.vivecraft$mainAttackSpeedBits == attackSpeedBits)
        {
            return;
        }

        ItemStack physicalMainHand = inventory.getItem(selectedSlot);
        ItemStack physicalOffhand = self.getItemBySlot(EquipmentSlot.OFFHAND);
        if (this.vivecraft$offhandAttackSpeedScratch == null) {
            this.vivecraft$offhandAttackSpeedScratch =
                new AttributeInstance(Attributes.ATTACK_SPEED, ignored -> {});
        }
        this.vivecraft$offhandAttackStrengthDelay = OffhandAttackSpeedAttributes.resolveDelay(
            this.vivecraft$offhandAttackSpeedScratch, liveAttackSpeed,
            physicalMainHand, physicalOffhand);
        this.vivecraft$offhandAttackStrengthInventoryVersion = inventoryVersion;
        this.vivecraft$offhandAttackStrengthSelectedSlot = selectedSlot;
        this.vivecraft$mainAttackSpeedBits = attackSpeedBits;
        this.vivecraft$offhandAttackStrengthDelayValid = true;
    }

    @Unique
    private boolean vivecraft$usesIndependentOffhandClock() {
        vivecraft$updateIndependentCooldownNegotiation();
        if (!this.vivecraft$offhandAttackStrength.enabled()) {
            return false;
        }

        Player self = (Player) (Object) this;
        if (self instanceof ServerPlayer serverPlayer) {
            ServerVivePlayer vivePlayer = ServerVRPlayers.getVivePlayer(serverPlayer);
            return vivePlayer != null && IndependentHandCooldownPolicy.usesOffhandClock(
                ServerConfig.DUAL_WIELDING.get(), vivePlayer.networkVersion,
                vivePlayer.getActiveItemBodyPart());
        }
        return IndependentHandCooldownPolicy.usesOffhandClock(
            ClientNetworking.SERVER_ALLOWS_DUAL_WIELDING,
            ClientNetworking.USED_NETWORK_VERSION,
            ClientNetworking.getActiveBodyPart());
    }
}
