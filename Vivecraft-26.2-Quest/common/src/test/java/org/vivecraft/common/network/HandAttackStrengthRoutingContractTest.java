package org.vivecraft.common.network;

import org.junit.jupiter.api.Assertions;
import org.junit.jupiter.api.Test;

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;

class HandAttackStrengthRoutingContractTest {
    private static final Path MAIN = Path.of("src", "main", "java");

    @Test
    void bodyPartReadsRestoreNestedClientOverrideWithoutPackets() throws IOException {
        String networking = source("org/vivecraft/client/network/ClientNetworking.java");
        Assertions.assertTrue(networking.contains("getAttackStrengthScaleForBodyPart("));
        Assertions.assertTrue(networking.contains("cannotAttackWithItemForBodyPart("));
        Assertions.assertTrue(networking.contains("VRBodyPart previousOverride = BODY_PART_CLIENT_OVERRIDE;"));
        Assertions.assertTrue(networking.contains("BODY_PART_CLIENT_OVERRIDE = previousOverride;"));

        int scaleHelper = networking.indexOf("getAttackStrengthScaleForBodyPart(");
        int scaleEnd = networking.indexOf("cannotAttackWithItemForBodyPart(", scaleHelper);
        String scaleBody = networking.substring(scaleHelper, scaleEnd);
        Assertions.assertFalse(scaleBody.contains("sendActiveBodyPart("));
        Assertions.assertTrue(scaleBody.contains("finally"));
    }

    @Test
    void eachRenderedHandUsesItsOwnNegotiatedClock() throws IOException {
        String swing = source(
            "org/vivecraft/client_vr/gameplay/trackers/SwingTracker.java");
        Assertions.assertTrue(swing.contains(
            "mainHand ? VRBodyPart.MAIN_HAND : VRBodyPart.OFF_HAND"));
        Assertions.assertTrue(swing.contains(
            "ClientNetworking.getAttackStrengthScaleForBodyPart("));
    }

    @Test
    void attackRoutingAndIndependentCooldownUseSeparateCapabilities() throws IOException {
        String networking = source("org/vivecraft/client/network/ClientNetworking.java");
        int routing = networking.indexOf("supportsOffhandAttackRouting()");
        int independent = networking.indexOf("supportsIndependentOffhandAttack()", routing);
        Assertions.assertTrue(routing >= 0 && independent > routing);

        String routingBody = networking.substring(routing, independent);
        Assertions.assertTrue(routingBody.contains("OffhandAttackRoutingPolicy.negotiated("));
        Assertions.assertTrue(routingBody.contains("SERVER_HAS_VIVECRAFT"));
        Assertions.assertTrue(routingBody.contains("SERVER_WANTS_DATA"));
        Assertions.assertTrue(routingBody.contains("SERVER_ALLOWS_DUAL_WIELDING"));
        Assertions.assertTrue(routingBody.contains("USED_NETWORK_VERSION"));

        int independentEnd = networking.indexOf("getTeleportUpLimit()", independent);
        String independentBody = networking.substring(independent, independentEnd);
        Assertions.assertTrue(independentBody.contains("supportsOffhandAttackRouting()"));
        Assertions.assertTrue(independentBody.contains("NetworkVersion.INDEPENDENT_HAND_COOLDOWN"));
    }

    @Test
    void physicalActionsUseHandClockAndRestoreOverrides() throws IOException {
        String swing = source(
            "org/vivecraft/client_vr/gameplay/trackers/SwingTracker.java");
        Assertions.assertTrue(swing.contains(
            "ClientNetworking.cannotAttackWithItemForBodyPart("));
        Assertions.assertTrue(swing.contains(
            "ClientHandActionTickGuard.global().claimEntityAttack("));
        Assertions.assertTrue(swing.contains(
            "ClientHandActionTickGuard.global().claimMiningContribution("));
        Assertions.assertTrue(swing.contains("VRBodyPart previousOverride"));
        Assertions.assertTrue(swing.contains("finally"));
        Assertions.assertTrue(swing.contains(
            "ClientNetworking.BODY_PART_CLIENT_OVERRIDE = previousOverride;"));
    }

    @Test
    void vanillaMainMiningStaysNativeBehindOneIntentCoordinator() throws IOException {
        String minecraft = source(
            "org/vivecraft/mixin/client_vr/MinecraftVRMixin.java");
        Assertions.assertFalse(minecraft.contains(
            "private boolean vivecraft$coordinateStartDestroyBlock("),
            "wrapping Vanilla startDestroyBlock regressed ordinary RT mining on Quest");
        Assertions.assertFalse(minecraft.contains(
            "private boolean vivecraft$coordinateContinueDestroyBlock("),
            "wrapping Vanilla continueDestroyBlock regressed ordinary RT mining on Quest");
        Assertions.assertTrue(minecraft.contains(
            "private boolean vivecraft$destroyReset(MultiPlayerGameMode instance)"));
        Assertions.assertTrue(minecraft.contains(
            "case STOP -> true;"));
        Assertions.assertTrue(minecraft.contains(
            "case KEEP -> false;"));

        String router = Files.readString(Path.of("..", "..", "Vivecraft-Essentials-Quest",
            "mod-core", "src", "main", "java", "org", "questcraft", "veq",
            "client", "input", "PerHandWorldActionRouter.java"));
        Assertions.assertTrue(router.contains(
            "guard.coordinateButtonMiningIntents("));
        Assertions.assertTrue(router.contains(
            "miningFrame.plan().routeNativeMain()"),
            "the coordinator must decide whether Vanilla RT owns this tick");
        Assertions.assertTrue(router.contains(
            "plan.customTargetSource()"),
            "an owner-pinned continuation must retain its exact input snapshot");
        Assertions.assertTrue(router.contains(
            "attackBreakUseChannelFree("),
            "routed logical-main Y must remain captured while RT owns mining");
        Assertions.assertTrue(router.contains(
            "attackBreakEntityDispatchAllowed("),
            "the retained Y press must not duplicate RT entity attacks");
        Assertions.assertFalse(router.contains(
            "? !uses.mainUse() && !attackShouldRoute"),
            "overlapping RT must not suppress held reverseHands Y until release");
        Assertions.assertFalse(router.contains(
            "ClientHandActionTickGuard.global().claimButtonMiningContribution("),
            "router dispatch must consume the coordinator plan rather than claim twice");
        Assertions.assertTrue(router.contains(
            "started && minecraft.gameMode.isDestroying()"),
            "a routed START must retain Vanilla's single-source start/continue cadence");

        String guard = source(
            "org/vivecraft/client_vr/gameplay/ClientHandActionTickGuard.java");
        Assertions.assertTrue(guard.contains(
            "private boolean miningSourceClaimed;"));
        Assertions.assertTrue(guard.contains(
            "reserveMiningSource(nativeTarget);"),
            "native RT must reserve the global mining source slot");
        Assertions.assertTrue(guard.contains(
            "private VRBodyPart buttonMiningSessionOwner;"),
            "the selected tool/body part must remain pinned for the session");

        String swing = source(
            "org/vivecraft/client_vr/gameplay/trackers/SwingTracker.java");
        Assertions.assertTrue(swing.contains(
            "ClientHandActionTickGuard.global().claimMiningContribution("),
            "physical swings must share the one global source claim");
        Assertions.assertTrue(swing.contains(
            "for (int hit = 0; hit < hits; hit++)"),
            "the accepted physical source must retain Vivecraft's measured swing strength");

        int noteBlocks = swing.indexOf("// roomscale noteblocks");
        int ordinaryMining = swing.indexOf("// roomscale mining", noteBlocks);
        Assertions.assertTrue(noteBlocks >= 0 && ordinaryMining > noteBlocks);
        String noteBlockBranch = swing.substring(noteBlocks, ordinaryMining);
        Assertions.assertTrue(noteBlockBranch.contains(
            "ClientHandActionTickGuard.global().claimMiningContribution("),
            "note-block strikes must not bypass the global mining-source claim");
        Assertions.assertTrue(noteBlockBranch.contains(
            "this.runWithBodyPart(BODYPARTS[i], true,"),
            "note-block strikes must retain the physical hand/body-part scope");
        Assertions.assertFalse(noteBlockBranch.contains("totalHits"),
            "note-block interaction must not inherit roomscale mining impulse");
        Assertions.assertTrue(noteBlockBranch.contains(
            "blockActionIssued = noteBlockDecision.accepted();"),
            "a rejected note-block source must not emit a ghost mining haptic");
    }

    @Test
    void unsupportedPeersLoseOnlyUnsafeOffhandCombatNotOrdinaryRoomscaleInteractions() throws IOException {
        String swing = source(
            "org/vivecraft/client_vr/gameplay/trackers/SwingTracker.java");
        int supportGate = swing.indexOf("boolean attackBodyPartSupported");
        int canAct = swing.indexOf("this.canAct[i] =");
        int entityGate = swing.indexOf("boolean entityAct", canAct);
        Assertions.assertTrue(supportGate >= 0 && canAct > supportGate && entityGate > canAct);
        Assertions.assertFalse(swing.substring(canAct, entityGate)
            .contains("supportsIndependentOffhandAttack"));
        Assertions.assertTrue(swing.substring(supportGate, canAct)
            .contains("supportsOffhandAttackRouting"));
        Assertions.assertTrue(swing.contains(
            "boolean entityAct = attackBodyPartSupported"));
        Assertions.assertTrue(swing.contains(
            "blockActionIssued = attackBodyPartSupported"));
    }

    @Test
    void sameDestroyTargetRestoresNestedOverride() throws IOException {
        String mixin = source(
            "org/vivecraft/mixin/client_vr/multiplayer/MultiPlayerGameModeVRMixin.java");
        int method = mixin.indexOf("vivecraft$dualWieldingSkipItemCheck");
        String body = mixin.substring(method);
        Assertions.assertTrue(body.contains(
            "vivecraft$hasPinnedDestroyOwner(destroyOwner)"),
            "a coordinated session must test only its pinned owner's tool");
        Assertions.assertTrue(body.contains(
            ".pinnedButtonMiningOwner("),
            "native RT must recover its coordinator-pinned owner before the item check");
        Assertions.assertTrue(body.contains(
            "vivecraft$resolvePinnedDestroyOwner("),
            "the wrapper must resolve an absent Vanilla override through the coordinator");
        Assertions.assertTrue(body.contains(
            "ClientNetworking.BODY_PART_CLIENT_OVERRIDE = destroyOwner;"),
            "the recovered native owner must scope Vanilla's destroyingItem check");
        Assertions.assertTrue(body.contains("VRBodyPart previousOverride"));
        Assertions.assertTrue(body.contains("finally"));
        Assertions.assertTrue(body.contains(
            "ClientNetworking.BODY_PART_CLIENT_OVERRIDE = previousOverride;"));
    }

    private static String source(String relative) throws IOException {
        return Files.readString(MAIN.resolve(relative));
    }
}
