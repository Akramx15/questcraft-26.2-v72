package org.vivecraft.common.network;

import net.minecraft.core.Holder;
import net.minecraft.world.entity.EquipmentSlot;
import net.minecraft.world.entity.ai.attributes.Attribute;
import net.minecraft.world.entity.ai.attributes.AttributeInstance;
import net.minecraft.world.entity.ai.attributes.AttributeModifier;
import net.minecraft.world.entity.ai.attributes.Attributes;
import net.minecraft.world.item.ItemStack;

import java.util.function.BiConsumer;

/** Computes an offhand-as-weapon delay without mutating a player's live attributes. */
public final class OffhandAttackSpeedAttributes {
    private OffhandAttackSpeedAttributes() {
    }

    public static float resolveDelay(
        AttributeInstance scratch,
        AttributeInstance liveAttackSpeed,
        ItemStack physicalMainHand,
        ItemStack physicalOffhand)
    {
        return resolveDelay(
            scratch, liveAttackSpeed,
            consumer -> physicalMainHand.forEachModifier(EquipmentSlot.MAINHAND, consumer),
            consumer -> physicalOffhand.forEachModifier(EquipmentSlot.MAINHAND, consumer));
    }

    static float resolveDelay(
        AttributeInstance scratch,
        AttributeInstance liveAttackSpeed,
        ModifierSource physicalMainHand,
        ModifierSource physicalOffhand)
    {
        scratch.replaceFrom(liveAttackSpeed);
        physicalMainHand.forEach((attribute, modifier) -> {
            if (attribute.equals(Attributes.ATTACK_SPEED)) {
                scratch.removeModifier(modifier.id());
            }
        });
        physicalOffhand.forEach((attribute, modifier) -> {
            if (attribute.equals(Attributes.ATTACK_SPEED)) {
                scratch.removeModifier(modifier.id());
                scratch.addTransientModifier(modifier);
            }
        });
        return (float) (20.0D / scratch.getValue());
    }

    @FunctionalInterface
    interface ModifierSource {
        void forEach(BiConsumer<Holder<Attribute>, AttributeModifier> consumer);
    }
}
