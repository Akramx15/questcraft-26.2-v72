package org.vivecraft.common.network;

import org.junit.jupiter.api.Assertions;
import org.junit.jupiter.api.Test;

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;

class IndependentHandCooldownContractTest {
    @Test
    void playerMixinVirtualizesEveryVanillaAttackClockBoundary() throws IOException {
        String source = Files.readString(Path.of(
            "src/main/java/org/vivecraft/mixin/world/entity/PlayerMixin.java"));
        Assertions.assertTrue(source.contains("method = \"cannotAttackWithItem\""));
        Assertions.assertTrue(source.contains("method = \"getAttackStrengthScale\""));
        Assertions.assertTrue(source.contains("method = \"getItemSwapScale\""));
        Assertions.assertTrue(source.contains("method = \"getCurrentItemAttackStrengthDelay\""));
        Assertions.assertTrue(source.contains("method = \"resetAttackStrengthTicker\""));
        Assertions.assertTrue(source.contains("method = \"resetOnlyAttackStrengthTicker\""));
        Assertions.assertTrue(source.contains("vivePlayer.getActiveItemBodyPart()"));
        Assertions.assertTrue(source.contains("ClientNetworking.getActiveBodyPart()"));
        Assertions.assertTrue(source.contains("NetworkVersion.INDEPENDENT_HAND_COOLDOWN") ||
            source.contains("IndependentHandCooldownPolicy.negotiated("));
    }

    @Test
    void localOffhandDelayUsesDetachedEquipmentAttributes() throws IOException {
        String source = Files.readString(Path.of(
            "src/main/java/org/vivecraft/mixin/world/entity/PlayerMixin.java"));
        Assertions.assertTrue(source.contains("new AttributeInstance(Attributes.ATTACK_SPEED"));
        Assertions.assertTrue(source.contains("offhandAttackSpeedScratch == null"));
        Assertions.assertTrue(source.contains("OffhandAttackSpeedAttributes.resolveDelay("));
        Assertions.assertTrue(source.contains("inventory.getItem(selectedSlot)"));
        String resolver = Files.readString(Path.of(
            "src/main/java/org/vivecraft/common/network/OffhandAttackSpeedAttributes.java"));
        Assertions.assertTrue(resolver.contains("scratch.replaceFrom(liveAttackSpeed)"));
        Assertions.assertTrue(resolver.contains("physicalOffhand.forEachModifier(EquipmentSlot.MAINHAND"));
        Assertions.assertFalse(source.contains("liveAttackSpeed.removeModifier("));
        Assertions.assertFalse(source.contains("liveAttackSpeed.addTransientModifier("));
    }
}
