package org.vivecraft.common.network;

import org.junit.jupiter.api.Assertions;
import org.junit.jupiter.api.Test;

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;

class PairedStrikeContractTest {
    private static String source(String relativePath) throws IOException {
        return Files.readString(Path.of("src/main/java").resolve(relativePath));
    }

    @Test
    void capabilityAndPayloadAreAppendOnlyAndNegotiated() throws IOException {
        Assertions.assertEquals(
            NetworkVersion.INDEPENDENT_HAND_COOLDOWN.ordinal() + 1,
            NetworkVersion.PAIRED_STRIKE.ordinal());

        String payloadIds = source("org/vivecraft/common/network/packet/PayloadIdentifier.java");
        int pairedStrikeId = payloadIds.indexOf("PAIRED_STRIKE");
        Assertions.assertTrue(pairedStrikeId >= 0);
        Assertions.assertFalse(payloadIds.substring(pairedStrikeId).contains(","),
            "new payload identifiers must be appended after PAIRED_STRIKE");

        String server = source("org/vivecraft/server/ServerNetworking.java");
        Assertions.assertTrue(server.contains("NetworkVersion.PAIRED_STRIKE.accepts(vivePlayer.networkVersion)"));
        Assertions.assertTrue(server.contains("packetConsumer.accept(getPairedStrikePayload(vivePlayer))"));
        Assertions.assertTrue(server.contains("payload instanceof PairedStrikePayloadS2C"));

        String client = source("org/vivecraft/client/network/ClientNetworking.java");
        Assertions.assertTrue(client.contains("SERVER_ALLOWS_PAIRED_STRIKE = false"));
        Assertions.assertTrue(client.contains("case PAIRED_STRIKE"));
    }

    @Test
    void serverDefaultsAreConservativeAndConfigurable() throws IOException {
        String config = source("org/vivecraft/server/config/ServerConfig.java");
        Assertions.assertTrue(config.contains("PAIRED_STRIKE_ENABLED"));
        Assertions.assertTrue(config.contains(".push(\"windowTicks\")"));
        Assertions.assertTrue(config.contains(".defineInRange(4, 1, 20)"));
        Assertions.assertTrue(config.contains(".push(\"minimumCharge\")"));
        Assertions.assertTrue(config.contains(".defineInRange(0.9, 0.0, 1.0)"));
        Assertions.assertTrue(config.contains(".push(\"allowPvp\")"));
        Assertions.assertTrue(config.contains(".define(false)"));
        Assertions.assertTrue(config.contains("ServerNetworking::getPairedStrikePayload"));
    }

    @Test
    void normalAttackPathOwnsEffectsAndScopedContextAlwaysEnds() throws IOException {
        String playerMixin = source("org/vivecraft/mixin/world/entity/PlayerMixin.java");
        Assertions.assertTrue(playerMixin.contains("@WrapMethod(method = \"attack\")"));
        Assertions.assertTrue(playerMixin.contains("original.call(target)"));
        Assertions.assertTrue(playerMixin.contains("PairedStrikeHurtContext.hurtSucceeded()"));
        Assertions.assertTrue(playerMixin.contains("if (bypass)"));
        Assertions.assertTrue(playerMixin.contains("vivePlayer.clearPairedStrike();"));
        Assertions.assertTrue(playerMixin.contains("tick, charge, itemAfter"));
        Assertions.assertTrue(playerMixin.contains("finally {"));
        Assertions.assertTrue(playerMixin.contains("PairedStrikeHurtContext.end();"));
        Assertions.assertFalse(playerMixin.contains("target.invulnerableTime = 0"));

        String livingMixin = source("org/vivecraft/mixin/world/entity/LivingEntityMixin.java");
        Assertions.assertTrue(livingMixin.contains("target = \"Lnet/minecraft/world/entity/LivingEntity;invulnerableTime:I\""));
        Assertions.assertTrue(livingMixin.contains("PairedStrikeHurtContext.modifyInvulnerableTime"));
        Assertions.assertTrue(livingMixin.contains("PairedStrikeHurtContext.recordHurtResult"));

        String context = source("org/vivecraft/server/PairedStrikeHurtContext.java");
        Assertions.assertTrue(context.contains("source.getEntity() == context.attacker"));
        Assertions.assertTrue(context.contains("context.target == target"));
        Assertions.assertTrue(context.contains("context.bypassConsumed = true"));
        Assertions.assertTrue(context.contains("context.attacker = null"));
        Assertions.assertTrue(context.contains("context.target = null"));
    }

    @Test
    void lifecycleAndItemChangesClearArmedState() throws IOException {
        String player = source("org/vivecraft/server/ServerVivePlayer.java");
        Assertions.assertTrue(player.contains("ItemStack.matches(this.pairedStrikeItem, current)"));
        Assertions.assertTrue(player.contains("this.pairedStrikeLevel == this.player.level()"));
        Assertions.assertTrue(player.contains("pairedStrikeTargetIsValid()"));
        Assertions.assertTrue(player.contains("this.pairedStrikeWindow.armed() && !pairedStrikeTargetIsValid()"));
        Assertions.assertTrue(player.contains("livingTarget.level() == this.player.level()"));
        Assertions.assertTrue(player.contains("!this.player.isAlive() || this.player.isRemoved()"));
        Assertions.assertTrue(player.contains("if (!vr)"));
        Assertions.assertTrue(player.contains("clearPairedStrike();"));

        String connection = source("org/vivecraft/mixin/server/ServerGamePacketListenerImplMixin.java");
        Assertions.assertTrue(connection.contains("vivecraft$clearPairedStrikeOnTeleport"));
        Assertions.assertTrue(connection.contains("vivePlayer.clearPairedStrike()"));

        String serverPlayer = source("org/vivecraft/mixin/server/ServerPlayerMixin.java");
        Assertions.assertTrue(serverPlayer.contains("vivecraft$clearPairedStrikeOnDimensionTeleport"));
        Assertions.assertTrue(serverPlayer.contains("vivecraft$clearPairedStrikeOnDirectTeleport"));
        Assertions.assertTrue(serverPlayer.contains("private void vivecraft$customDeathMessage"));

        String networking = source("org/vivecraft/server/ServerNetworking.java");
        Assertions.assertTrue(networking.contains("case TELEPORT"));
        Assertions.assertTrue(networking.contains("vivePlayer.clearPairedStrike()"));
    }
}
