package org.vivecraft.common.network;

import net.minecraft.SharedConstants;
import net.minecraft.resources.Identifier;
import net.minecraft.world.entity.ai.attributes.AttributeInstance;
import net.minecraft.world.entity.ai.attributes.AttributeModifier;
import net.minecraft.world.entity.ai.attributes.Attributes;
import net.minecraft.server.Bootstrap;
import org.junit.jupiter.api.Assertions;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.Test;

class OffhandAttackSpeedAttributesTest {
    private static final Identifier ITEM_SPEED = Identifier.withDefaultNamespace("base_attack_speed");

    @BeforeAll
    static void bootstrapMinecraftRegistries() {
        SharedConstants.tryDetectVersion();
        Bootstrap.bootStrap();
    }

    @Test
    void resolvesDifferentWeaponSpeedsAndLeavesLiveAttributeUntouched() {
        AttributeInstance live = new AttributeInstance(Attributes.ATTACK_SPEED, ignored -> {});
        live.setBaseValue(4.0D);
        live.addTransientModifier(new AttributeModifier(
            ITEM_SPEED, -3.0D, AttributeModifier.Operation.ADD_VALUE));
        AttributeInstance scratch = new AttributeInstance(Attributes.ATTACK_SPEED, ignored -> {});

        AttributeModifier main = attackSpeed(-3.0D);
        AttributeModifier offhand = attackSpeed(-3.2D);
        float delay = OffhandAttackSpeedAttributes.resolveDelay(
            scratch, live,
            consumer -> consumer.accept(Attributes.ATTACK_SPEED, main),
            consumer -> consumer.accept(Attributes.ATTACK_SPEED, offhand));

        Assertions.assertEquals(25.0F, delay, 1.0E-5F);
        Assertions.assertEquals(1.0D, live.getValue(), 1.0E-9D);
        Assertions.assertEquals(-3.0D, live.getModifier(ITEM_SPEED).amount(), 1.0E-9D);
    }

    @Test
    void emptyOffhandRestoresTheUnarmedFiveTickDelay() {
        AttributeInstance live = new AttributeInstance(Attributes.ATTACK_SPEED, ignored -> {});
        live.setBaseValue(4.0D);
        live.addTransientModifier(new AttributeModifier(
            ITEM_SPEED, -3.0D, AttributeModifier.Operation.ADD_VALUE));
        AttributeInstance scratch = new AttributeInstance(Attributes.ATTACK_SPEED, ignored -> {});

        float delay = OffhandAttackSpeedAttributes.resolveDelay(
            scratch, live,
            consumer -> consumer.accept(Attributes.ATTACK_SPEED, attackSpeed(-3.0D)),
            consumer -> {});

        Assertions.assertEquals(5.0F, delay, 1.0E-5F);
        Assertions.assertEquals(1.0D, live.getValue(), 1.0E-9D);
    }

    private static AttributeModifier attackSpeed(double amount) {
        return new AttributeModifier(
            ITEM_SPEED, amount, AttributeModifier.Operation.ADD_VALUE);
    }
}
