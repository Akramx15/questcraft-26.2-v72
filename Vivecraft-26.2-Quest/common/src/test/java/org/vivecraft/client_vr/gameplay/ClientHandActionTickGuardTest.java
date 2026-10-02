package org.vivecraft.client_vr.gameplay;

import net.minecraft.core.BlockPos;
import org.junit.jupiter.api.Assertions;
import org.junit.jupiter.api.Test;
import org.vivecraft.api.data.VRBodyPart;

class ClientHandActionTickGuardTest {
    private final ClientHandActionTickGuard guard = new ClientHandActionTickGuard();
    private final Object world = new Object();

    @Test
    void entityDedupeRemainsPerHandTickAndTarget() {
        Assertions.assertTrue(this.guard.claimEntityAttack(
            this.world, 10L, VRBodyPart.MAIN_HAND, 42));
        Assertions.assertFalse(this.guard.claimEntityAttack(
            this.world, 10L, VRBodyPart.MAIN_HAND, 42));
        Assertions.assertTrue(this.guard.claimEntityAttack(
            this.world, 10L, VRBodyPart.OFF_HAND, 42));
        Assertions.assertTrue(this.guard.claimEntityAttack(
            this.world, 10L, VRBodyPart.MAIN_HAND, 43));
        Assertions.assertTrue(this.guard.claimEntityAttack(
            this.world, 11L, VRBodyPart.MAIN_HAND, 42));
    }

    @Test
    void nativeRtWinsNewSameTargetSessionAndClaimsOneSource() {
        BlockPos target = new BlockPos(4, 5, 6);

        ClientHandActionTickGuard.ButtonMiningPlan plan = coordinate(
            20L, target, VRBodyPart.OFF_HAND, target, false, null);

        Assertions.assertTrue(plan.routeNativeMain());
        Assertions.assertTrue(plan.synthesizeNativePress());
        Assertions.assertEquals(
            ClientHandActionTickGuard.MiningDecision.REJECT_DUPLICATE,
            plan.routedDecision());
        Assertions.assertFalse(plan.hasCustomMiningDriver());
        Assertions.assertEquals(
            ClientHandActionTickGuard.MiningDecision.REJECT_DUPLICATE,
            this.guard.claimMiningContribution(
                this.world, 20L, VRBodyPart.MAIN_HAND, target, false, null));
        Assertions.assertEquals(
            ClientHandActionTickGuard.MiningDecision.REJECT_DUPLICATE,
            this.guard.claimMiningContribution(
                this.world, 20L, VRBodyPart.OFF_HAND, target, false, null));
    }

    @Test
    void routedYStartsThenContinuesWithExactlyOneDriverPerTick() {
        BlockPos target = new BlockPos(2, 64, -5);

        ClientHandActionTickGuard.ButtonMiningPlan start = coordinate(
            21L, null, VRBodyPart.OFF_HAND, target, false, null);
        assertCustom(start, ClientHandActionTickGuard.MiningDecision.START,
            VRBodyPart.OFF_HAND, ClientHandActionTickGuard.ButtonMiningInput.ROUTED);
        Assertions.assertEquals(
            ClientHandActionTickGuard.MiningDecision.REJECT_DUPLICATE,
            this.guard.claimMiningContribution(
                this.world, 21L, VRBodyPart.MAIN_HAND, target, false, null));

        ClientHandActionTickGuard.ButtonMiningPlan continuation = coordinate(
            22L, null, VRBodyPart.OFF_HAND, target, true, target);
        assertCustom(continuation, ClientHandActionTickGuard.MiningDecision.CONTINUE,
            VRBodyPart.OFF_HAND, ClientHandActionTickGuard.ButtonMiningInput.ROUTED);
        Assertions.assertEquals(
            ClientHandActionTickGuard.MiningDecision.REJECT_DUPLICATE,
            this.guard.claimMiningContribution(
                this.world, 22L, VRBodyPart.OFF_HAND, target, true, target));
    }

    @Test
    void nativeOwnerSurvivesRtReleaseWhileRoutedYKeepsSameTarget() {
        BlockPos target = new BlockPos(-8, 70, 4);

        ClientHandActionTickGuard.ButtonMiningPlan start = coordinate(
            30L, target, VRBodyPart.OFF_HAND, null, false, null);
        Assertions.assertTrue(start.routeNativeMain());
        Assertions.assertTrue(start.synthesizeNativePress());

        ClientHandActionTickGuard.ButtonMiningPlan joined = coordinate(
            31L, target, VRBodyPart.OFF_HAND, target, true, target);
        Assertions.assertTrue(joined.routeNativeMain());
        Assertions.assertFalse(joined.synthesizeNativePress());
        Assertions.assertFalse(joined.hasCustomMiningDriver());

        ClientHandActionTickGuard.ButtonMiningPlan handoff = coordinate(
            32L, null, VRBodyPart.OFF_HAND, target, true, target);
        assertCustom(handoff, ClientHandActionTickGuard.MiningDecision.CONTINUE,
            VRBodyPart.MAIN_HAND, ClientHandActionTickGuard.ButtonMiningInput.ROUTED);
        Assertions.assertEquals(
            ClientHandActionTickGuard.MiningStopDecision.KEEP,
            this.guard.miningStopDecision(this.world, 32L, true, target));

        coordinate(33L, null, VRBodyPart.OFF_HAND, null, true, target);
        Assertions.assertEquals(
            ClientHandActionTickGuard.MiningStopDecision.STOP,
            this.guard.miningStopDecision(this.world, 33L, true, target));
    }

    @Test
    void routedOwnerCannotBeTakenOverByRtJoiningSameTarget() {
        BlockPos target = new BlockPos(7, 8, 9);

        assertCustom(
            coordinate(40L, null, VRBodyPart.OFF_HAND, target, false, null),
            ClientHandActionTickGuard.MiningDecision.START,
            VRBodyPart.OFF_HAND, ClientHandActionTickGuard.ButtonMiningInput.ROUTED);

        ClientHandActionTickGuard.ButtonMiningPlan both = coordinate(
            41L, target, VRBodyPart.OFF_HAND, target, true, target);
        assertCustom(both, ClientHandActionTickGuard.MiningDecision.CONTINUE,
            VRBodyPart.OFF_HAND, ClientHandActionTickGuard.ButtonMiningInput.ROUTED);
        Assertions.assertFalse(both.routeNativeMain());

        ClientHandActionTickGuard.ButtonMiningPlan rtOnly = coordinate(
            42L, target, VRBodyPart.OFF_HAND, null, true, target);
        assertCustom(rtOnly, ClientHandActionTickGuard.MiningDecision.CONTINUE,
            VRBodyPart.OFF_HAND, ClientHandActionTickGuard.ButtonMiningInput.NATIVE_MAIN);
        Assertions.assertFalse(rtOnly.routeNativeMain());
        Assertions.assertEquals(
            ClientHandActionTickGuard.MiningStopDecision.KEEP,
            this.guard.miningStopDecision(this.world, 42L, true, target));
    }

    @Test
    void differentTargetsNeverDriveOrResetTheOldSessionInOneTick() {
        BlockPos active = new BlockPos(1, 2, 3);
        BlockPos replacement = active.east();

        assertCustom(
            coordinate(50L, null, VRBodyPart.OFF_HAND, active, false, null),
            ClientHandActionTickGuard.MiningDecision.START,
            VRBodyPart.OFF_HAND, ClientHandActionTickGuard.ButtonMiningInput.ROUTED);

        ClientHandActionTickGuard.ButtonMiningPlan blocked = coordinate(
            51L, replacement, VRBodyPart.OFF_HAND, null, true, active);
        Assertions.assertFalse(blocked.routeNativeMain());
        Assertions.assertFalse(blocked.hasCustomMiningDriver());
        Assertions.assertEquals(
            ClientHandActionTickGuard.MiningStopDecision.STOP,
            this.guard.miningStopDecision(this.world, 51L, true, active));

        this.guard.finishButtonMiningSession(this.world, active);
        ClientHandActionTickGuard.ButtonMiningPlan nextTick = coordinate(
            52L, replacement, VRBodyPart.OFF_HAND, null, false, null);
        Assertions.assertTrue(nextTick.routeNativeMain());
        Assertions.assertTrue(nextTick.synthesizeNativePress());
    }

    @Test
    void nativeNewSessionRejectsDifferentRoutedTargetWithoutTakingIt() {
        BlockPos nativeTarget = new BlockPos(11, 63, 11);
        BlockPos routedTarget = nativeTarget.above();

        ClientHandActionTickGuard.ButtonMiningPlan plan = coordinate(
            60L, nativeTarget, VRBodyPart.OFF_HAND, routedTarget, false, null);

        Assertions.assertTrue(plan.routeNativeMain());
        Assertions.assertEquals(
            ClientHandActionTickGuard.MiningDecision.REJECT_DIFFERENT_TARGET,
            plan.routedDecision());
        Assertions.assertFalse(plan.hasCustomMiningDriver());
    }

    @Test
    void reverseHandsRoutedMainYIsNotMisclassifiedAsNativeRt() {
        BlockPos target = new BlockPos(9, 3, -12);

        ClientHandActionTickGuard.ButtonMiningPlan plan = coordinate(
            70L, null, VRBodyPart.MAIN_HAND, target, false, null);

        assertCustom(plan, ClientHandActionTickGuard.MiningDecision.START,
            VRBodyPart.MAIN_HAND, ClientHandActionTickGuard.ButtonMiningInput.ROUTED);
        Assertions.assertFalse(plan.routeNativeMain());
    }

    @Test
    void joiningAnExistingNativeSessionDoesNotSynthesizeAnotherStart() {
        BlockPos target = new BlockPos(12, 4, -3);

        ClientHandActionTickGuard.ButtonMiningPlan plan = coordinate(
            80L, target, VRBodyPart.OFF_HAND, null, true, target);

        Assertions.assertTrue(plan.routeNativeMain());
        Assertions.assertFalse(plan.synthesizeNativePress());
        Assertions.assertFalse(plan.hasCustomMiningDriver());
    }

    @Test
    void nativeAndRoutedSessionsExposeOnlyTheirExactCurrentPinnedOwner() {
        BlockPos nativeTarget = new BlockPos(8, 40, 12);
        coordinate(85L, nativeTarget, VRBodyPart.OFF_HAND, null, false, null);
        Assertions.assertEquals(VRBodyPart.MAIN_HAND,
            this.guard.pinnedButtonMiningOwner(this.world, 85L, nativeTarget));
        Assertions.assertNull(this.guard.pinnedButtonMiningOwner(
            this.world, 84L, nativeTarget));
        Assertions.assertNull(this.guard.pinnedButtonMiningOwner(
            this.world, 85L, nativeTarget.above()));
        Assertions.assertNull(this.guard.pinnedButtonMiningOwner(
            new Object(), 85L, nativeTarget));

        BlockPos routedTarget = nativeTarget.east();
        coordinate(86L, null, VRBodyPart.OFF_HAND, routedTarget, false, null);
        Assertions.assertEquals(VRBodyPart.OFF_HAND,
            this.guard.pinnedButtonMiningOwner(this.world, 86L, routedTarget));

        this.guard.finishButtonMiningSession(this.world, routedTarget);
        Assertions.assertNull(this.guard.pinnedButtonMiningOwner(
            this.world, 86L, routedTarget));
    }

    @Test
    void missingButtonFrameAndWorldReplacementFailClosed() {
        BlockPos target = new BlockPos(21, 22, 23);
        assertCustom(
            coordinate(90L, null, VRBodyPart.OFF_HAND, target, false, null),
            ClientHandActionTickGuard.MiningDecision.START,
            VRBodyPart.OFF_HAND, ClientHandActionTickGuard.ButtonMiningInput.ROUTED);

        Assertions.assertEquals(
            ClientHandActionTickGuard.MiningStopDecision.DEFER_TO_LEGACY,
            this.guard.miningStopDecision(this.world, 91L, true, target));
        Assertions.assertEquals(
            ClientHandActionTickGuard.MiningDecision.START,
            this.guard.claimMiningContribution(
                new Object(), 91L, VRBodyPart.MAIN_HAND, target, false, null));
    }

    @Test
    void roomScaleMiningAlsoHasOneGlobalSourceClaimPerTick() {
        BlockPos target = BlockPos.ZERO;
        Assertions.assertEquals(
            ClientHandActionTickGuard.MiningDecision.START,
            this.guard.claimMiningContribution(
                this.world, 100L, VRBodyPart.MAIN_HAND, target, false, null));
        Assertions.assertEquals(
            ClientHandActionTickGuard.MiningDecision.REJECT_DUPLICATE,
            this.guard.claimMiningContribution(
                this.world, 100L, VRBodyPart.OFF_HAND, target, false, null));
        Assertions.assertEquals(
            ClientHandActionTickGuard.MiningDecision.REJECT_DIFFERENT_TARGET,
            this.guard.claimMiningContribution(
                this.world, 100L, VRBodyPart.OFF_HAND, target.above(), false, null));
        Assertions.assertEquals(
            ClientHandActionTickGuard.MiningDecision.START,
            this.guard.claimMiningContribution(
                this.world, 101L, VRBodyPart.OFF_HAND, target, false, null));
    }

    @Test
    void compatibilityNativeObservationReservesTheGlobalSourceSlot() {
        BlockPos target = new BlockPos(3, 14, 15);
        this.guard.observeButtonMiningTargets(this.world, 110L, target, target);
        this.guard.observeNativeMainButtonMiningIntent(this.world, 110L, target);

        Assertions.assertEquals(
            ClientHandActionTickGuard.MiningDecision.REJECT_DUPLICATE,
            this.guard.claimButtonMiningContribution(
                this.world, 110L, VRBodyPart.OFF_HAND, target, false, null));
        Assertions.assertEquals(
            ClientHandActionTickGuard.MiningStopDecision.DEFER_TO_LEGACY,
            this.guard.miningStopDecision(this.world, 110L, true, target));
    }

    private ClientHandActionTickGuard.ButtonMiningPlan coordinate(
        long tick,
        BlockPos nativeTarget,
        VRBodyPart routedBodyPart,
        BlockPos routedTarget,
        boolean destroying,
        BlockPos currentTarget)
    {
        return this.guard.coordinateButtonMiningIntents(
            this.world, tick, nativeTarget, routedBodyPart, routedTarget,
            destroying, currentTarget);
    }

    private static void assertCustom(
        ClientHandActionTickGuard.ButtonMiningPlan plan,
        ClientHandActionTickGuard.MiningDecision decision,
        VRBodyPart owner,
        ClientHandActionTickGuard.ButtonMiningInput source)
    {
        Assertions.assertTrue(plan.hasCustomMiningDriver());
        Assertions.assertFalse(plan.routeNativeMain());
        Assertions.assertFalse(plan.synthesizeNativePress());
        Assertions.assertEquals(decision, plan.routedDecision());
        Assertions.assertEquals(owner, plan.sessionOwner());
        Assertions.assertEquals(source, plan.customTargetSource());
    }
}
