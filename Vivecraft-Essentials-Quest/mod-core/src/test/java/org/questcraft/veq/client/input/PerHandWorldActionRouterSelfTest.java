package org.questcraft.veq.client.input;

import net.minecraft.core.BlockPos;
import net.minecraft.core.Direction;
import net.minecraft.core.Holder;
import net.minecraft.core.component.DataComponentMap;
import net.minecraft.SharedConstants;
import net.minecraft.server.Bootstrap;
import net.minecraft.world.InteractionHand;
import net.minecraft.world.item.ItemStack;
import net.minecraft.world.item.Items;
import net.minecraft.world.level.ClipContext;
import net.minecraft.world.phys.AABB;
import net.minecraft.world.phys.BlockHitResult;
import net.minecraft.world.phys.Vec3;
import org.vivecraft.client_vr.provider.ControllerType;
import org.vivecraft.client_vr.provider.ExternalHandUseState;
import org.vivecraft.client_vr.gameplay.ScopedUseItemOnContext;

import java.util.ArrayList;
import java.util.List;

import static org.questcraft.veq.client.input.LeftUseCapture.Sample.DOWN;
import static org.questcraft.veq.client.input.LeftUseCapture.Sample.RELEASED;
import static org.questcraft.veq.client.input.LeftUseCapture.Sample.UNKNOWN;

/** Host-only end-to-end contract for v67 hand semantics and fail-closed latches. */
public final class PerHandWorldActionRouterSelfTest {
    private PerHandWorldActionRouterSelfTest() {
    }

    public static void main(String[] args) {
        routesAreLogicalAndIndependent();
        physicalBTargetDoesNotDoubleApplyReverseHands();
        physicalBRequiresSourceAndTargetOwnership();
        ownershipFailsClosed();
        blockUseRequiresRangeAndWorldBorder();
        missAndAirMiningTargetsFailClosed();
        menuTargetsUseMainHandWithoutRebindingTheController();
        translatedBlockMenuScopeIsExactAndExceptionSafe();
        MenuBlockAttemptLatchSelfTest.runAll();
        entityOcclusionReachAndControllerRayBoundsAreStable();
        itemAwareFluidProfilesAreStable();
        attackBreakUsesProviderResolvedHandExactlyOnce();
        reverseHandsMainYSurvivesRtHandoffWithoutDuplicateEntityAttack();
        useLatchesDoNotReplayAcrossOwnershipLoss();
        lifecycleReplacementSuppressesHeldInputs();
        simultaneousAndLongUsesShareTheProductionDispatcher();
        explicitMainUseSuppressesSameHandAttack();
    }

    private static void reverseHandsMainYSurvivesRtHandoffWithoutDuplicateEntityAttack() {
        AttackBreakThisHandLatch latch = new AttackBreakThisHandLatch();
        require(PerHandWorldActionRouter.attackBreakUseChannelFree(
                        InteractionHand.MAIN_HAND, false, false),
                "reverseHands logical-main Y stays eligible while RT is held");

        AttackBreakThisHandLatch.Outcome bothHeld = latch.update(
                ControllerType.RIGHT, DOWN, true);
        require(bothHeld.held() && bothHeld.pressed(),
                "Y is captured instead of being suppressed by overlapping RT");
        require(!PerHandWorldActionRouter.attackBreakEntityDispatchAllowed(
                        InteractionHand.MAIN_HAND, true),
                "overlapping RT owns the one logical-main entity attack");

        AttackBreakThisHandLatch.Outcome yAfterRtRelease = latch.update(
                ControllerType.RIGHT, DOWN, true);
        require(yAfterRtRelease.held() && !yAfterRtRelease.pressed(),
                "held Y remains available for same-block mining after RT release");
        require(PerHandWorldActionRouter.attackBreakEntityDispatchAllowed(
                        InteractionHand.MAIN_HAND, false),
                "Y regains entity dispatch only after RT stops routing");
    }

    private static void menuTargetsUseMainHandWithoutRebindingTheController() {
        require(PerHandWorldActionPolicy.interactionHandForBlockMenu(
                        InteractionHand.OFF_HAND, false, true) == InteractionHand.MAIN_HAND,
                "left-trigger menu targets use the protocol-compatible main hand");
        require(PerHandWorldActionPolicy.interactionHandForBlockMenu(
                        InteractionHand.OFF_HAND, true, true) == InteractionHand.OFF_HAND,
                "L2 plus sneak preserves offhand placement over a menu block");
        require(PerHandWorldActionPolicy.interactionHandForBlockMenu(
                        InteractionHand.OFF_HAND, false, false) == InteractionHand.OFF_HAND,
                "ordinary left-trigger item and fluid uses remain offhand");
        require(PerHandWorldActionPolicy.interactionHandForBlockMenu(
                        InteractionHand.MAIN_HAND, false, true) == InteractionHand.MAIN_HAND,
                "B main-hand menu use is unchanged");
        require(PerHandWorldActionPolicy.interactionHandForEntity(
                        InteractionHand.OFF_HAND) == InteractionHand.OFF_HAND,
                "entity interaction remains item-first on the requested offhand");

        PerHandWorldActionPolicy.Route offhand = PerHandWorldActionPolicy.route(
                PerHandWorldActionPolicy.Command.OFFHAND_TRIGGER_USE);
        require(offhand.controller() == ControllerType.LEFT &&
                        offhand.hand() == InteractionHand.OFF_HAND,
                "menu protocol translation never rebinds the left controller ray or haptic");
    }

    private static void translatedBlockMenuScopeIsExactAndExceptionSafe() {
        BlockHitResult hit = new BlockHitResult(
                new Vec3(-2.0D, 4.25D, 7.0D), Direction.NORTH,
                new BlockPos(-2, 4, 7), false);
        HandTargetSnapshot left = new HandTargetSnapshot(
                ControllerType.LEFT, InteractionHand.OFF_HAND,
                new Vec3(-1.0D, 4.0D, 3.0D), new Vec3(0.0D, 0.05D, 1.0D),
                hit, null, hit);

        boolean called = PerHandWorldActionRouter.withBlockInteractionContext(
                left, InteractionHand.MAIN_HAND, () -> {
                    ScopedUseItemOnContext.Snapshot context =
                            ScopedUseItemOnContext.current();
                    require(context != null &&
                                    context.logicalController() == ControllerType.LEFT &&
                                    context.rayOrigin().equals(left.start()) &&
                                    context.hitLocation().equals(hit.getLocation()) &&
                                    context.blockPosition().equals(hit.getBlockPos()) &&
                                    context.hitFace() == Direction.NORTH,
                            "translated MAIN_HAND call retains the immutable logical-left target");
                    return true;
                });
        require(called && ScopedUseItemOnContext.current() == null,
                "translated menu context is cleared after a successful useItemOn");

        try {
            PerHandWorldActionRouter.withBlockInteractionContext(
                    left, InteractionHand.MAIN_HAND, () -> {
                        throw new IllegalStateException("synthetic useItemOn failure");
                    });
            throw new AssertionError("synthetic failure did not propagate");
        } catch (IllegalStateException expected) {
            require(ScopedUseItemOnContext.current() == null,
                    "translated menu context is cleared in finally after failure");
        }

        PerHandWorldActionRouter.withBlockInteractionContext(
                left, InteractionHand.OFF_HAND, () -> {
                    require(ScopedUseItemOnContext.current() == null,
                            "ordinary offhand use does not install translated context");
                    return true;
                });
    }

    private static void blockUseRequiresRangeAndWorldBorder() {
        require(PerHandWorldActionPolicy.allowBlockUse(true, true),
                "in-range block inside the world border may route");
        require(!PerHandWorldActionPolicy.allowBlockUse(false, true),
                "out-of-range block may not route");
        require(!PerHandWorldActionPolicy.allowBlockUse(true, false),
                "block outside the world border may not reach useItemOn");
        require(PerHandWorldActionPolicy.blockUseDecision(true, true, true) ==
                        PerHandWorldActionPolicy.BlockUseDecision.USE_BLOCK,
                "valid block target routes to useItemOn");
        require(PerHandWorldActionPolicy.blockUseDecision(true, false, true) ==
                        PerHandWorldActionPolicy.BlockUseDecision.STOP,
                "out-of-range BLOCK stops without item fallback");
        require(PerHandWorldActionPolicy.blockUseDecision(true, true, false) ==
                        PerHandWorldActionPolicy.BlockUseDecision.STOP,
                "out-of-border BLOCK stops without item fallback");
        require(PerHandWorldActionPolicy.blockUseDecision(false, false, false) ==
                        PerHandWorldActionPolicy.BlockUseDecision.USE_ITEM,
                "a miss may use the held item");
    }

    private static void missAndAirMiningTargetsFailClosed() {
        BlockPos pos = new BlockPos(2, 3, 4);
        BlockHitResult block = new BlockHitResult(
                new Vec3(2.5D, 3.5D, 4.5D), Direction.UP, pos, false);
        BlockHitResult miss = BlockHitResult.miss(
                new Vec3(2.5D, 3.5D, 4.5D), Direction.UP, pos);
        require(PerHandWorldActionRouter.isMineableBlockHit(block, false),
                "a real non-air BLOCK may become a mining intent");
        require(!PerHandWorldActionRouter.isMineableBlockHit(miss, false),
                "BlockHitResult.miss must not become a phantom START intent");
        require(!PerHandWorldActionRouter.isMineableBlockHit(block, true),
                "a stale BLOCK snapshot completed by the other hand fails closed");
    }

    private static void routesAreLogicalAndIndependent() {
        assertRoute(PerHandWorldActionPolicy.Command.MAIN_ATTACK,
                ControllerType.RIGHT, InteractionHand.MAIN_HAND);
        assertRoute(PerHandWorldActionPolicy.Command.MAIN_USE_BUTTON,
                ControllerType.RIGHT, InteractionHand.MAIN_HAND);
        assertRoute(PerHandWorldActionPolicy.Command.OFFHAND_TRIGGER_USE,
                ControllerType.LEFT, InteractionHand.OFF_HAND);
        ControllerType[] controllers = ControllerType.values();
        require(controllers.length == 2 && controllers[0] == ControllerType.RIGHT &&
                        controllers[1] == ControllerType.LEFT,
                "ControllerType ordinal ABI must remain RIGHT=0, LEFT=1");
    }

    private static void attackBreakUsesProviderResolvedHandExactlyOnce() {
        for (boolean reverseHands : new boolean[]{false, true}) {
            ControllerType logical = QuestHandMapping.logicalFromPhysical(
                    ControllerType.LEFT, reverseHands);
            PerHandWorldActionPolicy.Route route =
                    PerHandWorldActionPolicy.attackBreakThisHand(logical);
            require(route.controller() == logical,
                    "Y keeps the provider-resolved logical controller");
            require(route.hand() == QuestHandMapping.interactionHand(logical),
                    "Y derives its InteractionHand without applying reverseHands twice");
        }
        require(PerHandWorldActionPolicy.allowAttackBreakThisHand(
                        InteractionHand.MAIN_HAND, true, false),
                "main-hand Y remains safe without an offhand protocol");
        require(!PerHandWorldActionPolicy.allowAttackBreakThisHand(
                        InteractionHand.OFF_HAND, true, false),
                "true offhand Y fails closed on Vanilla peers");
        require(PerHandWorldActionPolicy.allowAttackBreakThisHand(
                        InteractionHand.OFF_HAND, true, true),
                "older dual-wield peers route true offhand Y with a shared clock");
        require(PerHandWorldActionPolicy.allowAttackBreakThisHand(
                        InteractionHand.OFF_HAND, true, true),
                "exact peers route true offhand Y with an independent clock");
        require(!PerHandWorldActionPolicy.allowAttackBreakThisHand(
                        InteractionHand.MAIN_HAND, false, true),
                "ownership remains mandatory for either hand");
    }

    private static void physicalBTargetDoesNotDoubleApplyReverseHands() {
        for (boolean reverseHands : new boolean[]{false, true}) {
            ControllerType sampledOrigin = QuestHandMapping.logicalFromPhysical(
                    ControllerType.RIGHT, reverseHands);
            require(sampledOrigin == (reverseHands ? ControllerType.LEFT : ControllerType.RIGHT),
                    "provider maps physical B origin once");
            PerHandWorldActionPolicy.Route target = PerHandWorldActionPolicy.route(
                    PerHandWorldActionPolicy.Command.MAIN_USE_BUTTON);
            require(target.controller() == ControllerType.RIGHT &&
                            target.hand() == InteractionHand.MAIN_HAND,
                    "B semantic target remains logical main hand after provider mapping");
        }
    }

    private static void physicalBRequiresSourceAndTargetOwnership() {
        require(PerHandWorldActionPolicy.allowBoundMainUse(true, true, true),
                "world-owned source and target route B");
        require(!PerHandWorldActionPolicy.allowBoundMainUse(false, true, true),
                "logical RIGHT target ownership is mandatory");
        require(!PerHandWorldActionPolicy.allowBoundMainUse(true, false, true),
                "physical B origin ownership/tracking is mandatory under reverseHands");
        require(!PerHandWorldActionPolicy.allowBoundMainUse(true, true, false),
                "disabled source action fails closed");
    }

    private static void ownershipFailsClosed() {
        require(HandOwnershipSnapshot.worldAllowed(
                        true, true, true, HandActionPriority.Owner.WORLD, false),
                "fully valid world hand routes");
        for (HandActionPriority.Owner owner : HandActionPriority.Owner.values()) {
            if (owner != HandActionPriority.Owner.WORLD) {
                require(!HandOwnershipSnapshot.worldAllowed(true, true, true, owner, false),
                        owner + " must retain the hand");
            }
        }
        require(!HandOwnershipSnapshot.worldAllowed(
                        false, true, true, HandActionPriority.Owner.WORLD, false),
                "lifecycle loss blocks world");
        require(!HandOwnershipSnapshot.worldAllowed(
                        true, false, true, HandActionPriority.Owner.WORLD, false),
                "tracking loss blocks world");
        require(!HandOwnershipSnapshot.worldAllowed(
                        true, true, false, HandActionPriority.Owner.WORLD, false),
                "invalid Aim pose blocks world");
        require(!HandOwnershipSnapshot.worldAllowed(
                        true, true, true, HandActionPriority.Owner.WORLD, true),
                "notched/drawing bow owns both hands");
    }

    private static void itemAwareFluidProfilesAreStable() {
        SharedConstants.tryDetectVersion();
        Bootstrap.bootStrap();

        require(HandRaycastFluidPolicy.forUse(stackForPolicy(Items.BUCKET)) ==
                        ClipContext.Fluid.SOURCE_ONLY,
                "empty bucket targets source fluid");
        require(HandRaycastFluidPolicy.forUse(stackForPolicy(Items.WATER_BUCKET)) ==
                        ClipContext.Fluid.NONE,
                "filled bucket ignores fluid");
        require(HandRaycastFluidPolicy.forUse(stackForPolicy(Items.STONE)) ==
                        ClipContext.Fluid.NONE,
                "ordinary block interactions ignore fluid");
    }

    private static ItemStack stackForPolicy(net.minecraft.world.item.Item item) {
        // This host-only test has no world registry loader. A direct holder keeps
        // the actual vanilla item identity while avoiding unrelated component data.
        return new ItemStack(Holder.direct(item, DataComponentMap.EMPTY));
    }

    private static void entityOcclusionReachAndControllerRayBoundsAreStable() {
        require(PerHandWorldActionPolicy.entityUseDecision(true, true) ==
                        PerHandWorldActionPolicy.EntityUseDecision.INTERACT,
                "in-border entity within reach may interact");
        require(PerHandWorldActionPolicy.entityUseDecision(false, true) ==
                        PerHandWorldActionPolicy.EntityUseDecision.STOP,
                "world border rejects entity interaction and item fallback");
        require(PerHandWorldActionPolicy.entityUseDecision(true, false) ==
                        PerHandWorldActionPolicy.EntityUseDecision.USE_ITEM,
                "out-of-reach entity preserves Vanilla item fallback");
        require(HandTargetSnapshot.entityPrecedesBlock(false, 25.0D, 0.0D),
                "entity is primary when no block occludes it");
        require(HandTargetSnapshot.entityPrecedesBlock(true, 4.0D, 9.0D),
                "entity before block is primary");
        require(!HandTargetSnapshot.entityPrecedesBlock(true, 9.0D, 4.0D),
                "entity behind block is occluded");
        require(!HandTargetSnapshot.entityPrecedesBlock(true, 4.0D, 4.0D),
                "equal-distance block wins fail-closed");

        AABB bounds = HandTargetSnapshot.raySearchBounds(
                new Vec3(10.0D, 2.0D, -3.0D),
                new Vec3(14.0D, 2.0D, -3.0D));
        require(bounds.minX == 9.0D && bounds.maxX == 15.0D &&
                        bounds.minY == 1.0D && bounds.maxY == 3.0D &&
                        bounds.minZ == -4.0D && bounds.maxZ == -2.0D,
                "entity query bounds follow the controller-ray segment");
        require(bounds.minX > 0.0D,
                "room-scale ray query must not expand from the player root");
    }

    private static void useLatchesDoNotReplayAcrossOwnershipLoss() {
        IndependentHandUseLatch latch = new IndependentHandUseLatch();
        IndependentHandUseLatch.Outcome both = latch.update(DOWN, true, DOWN, true);
        require(both.mainUse() && both.offhandUse(),
                "independent B-main and LT-offhand edges may route together");

        IndependentHandUseLatch.Outcome lostMain = latch.update(UNKNOWN, false, DOWN, true);
        require(!lostMain.mainUse() && lostMain.offhandUse(),
                "main ownership loss cannot cancel the independent offhand hold");
        IndependentHandUseLatch.Outcome recoveredHeld = latch.update(DOWN, true, DOWN, true);
        require(!recoveredHeld.mainUse() && recoveredHeld.offhandUse(),
                "held B cannot replay after ownership recovery");
        latch.update(RELEASED, true, DOWN, true);
        require(latch.update(DOWN, true, DOWN, true).mainUse(),
                "B rearms only after its confirmed release");

    }

    private static void lifecycleReplacementSuppressesHeldInputs() {
        HandActionLifecycle lifecycle = new HandActionLifecycle();
        Object level = new Object();
        Object player = new Object();
        Object inventory = new Object();
        Object menu = new Object();
        Object gameMode = new Object();
        Object vrRuntime = new Object();
        Object vrPlayer = new Object();

        require(lifecycle.observe(true, level, player, inventory, menu, gameMode,
                        vrRuntime, vrPlayer) == HandActionLifecycle.Transition.ENTERED,
                "first runtime identity is a guarded lifecycle entry");
        require(lifecycle.observe(true, level, player, inventory, menu, gameMode,
                        vrRuntime, vrPlayer) == HandActionLifecycle.Transition.STABLE,
                "unchanged identity becomes routable");

        Object[] replacements = {
                new Object(), new Object(), new Object(), new Object(),
                new Object(), new Object(), new Object()
        };
        level = replacements[0];
        requireReplaced(lifecycle, level, player, inventory, menu, gameMode, vrRuntime, vrPlayer,
                "level");
        player = replacements[1];
        requireReplaced(lifecycle, level, player, inventory, menu, gameMode, vrRuntime, vrPlayer,
                "player");
        inventory = replacements[2];
        requireReplaced(lifecycle, level, player, inventory, menu, gameMode, vrRuntime, vrPlayer,
                "inventory");
        menu = replacements[3];
        requireReplaced(lifecycle, level, player, inventory, menu, gameMode, vrRuntime, vrPlayer,
                "menu");
        gameMode = replacements[4];
        requireReplaced(lifecycle, level, player, inventory, menu, gameMode, vrRuntime, vrPlayer,
                "game mode");
        vrRuntime = replacements[5];
        requireReplaced(lifecycle, level, player, inventory, menu, gameMode, vrRuntime, vrPlayer,
                "VR runtime");
        vrPlayer = replacements[6];
        requireReplaced(lifecycle, level, player, inventory, menu, gameMode, vrRuntime, vrPlayer,
                "VR player");

        require(lifecycle.observe(false, level, player, inventory, menu, gameMode,
                        vrRuntime, vrPlayer) == HandActionLifecycle.Transition.LOST,
                "runtime loss invalidates the complete identity");
        require(lifecycle.observe(false, level, player, inventory, menu, gameMode,
                        vrRuntime, vrPlayer) == HandActionLifecycle.Transition.INACTIVE,
                "repeated inactive ticks do not create new sessions");
        require(lifecycle.observe(true, level, player, inventory, menu, gameMode,
                        vrRuntime, vrPlayer) == HandActionLifecycle.Transition.ENTERED,
                "VR restart is a new guarded lifecycle even with the same world refs");

        PerHandTransientState state = new PerHandTransientState();
        IndependentHandUseLatch.Outcome started = state.updateUses(DOWN, true, DOWN, true);
        require(started.mainUse() && started.offhandUse(),
                "both use captures route before lifecycle replacement");
        require(state.updateMainAttacks(DOWN, true, RELEASED, true) &&
                        state.beginMainAttack(),
                "RT capture/key state route before lifecycle replacement");
        require(state.updateAttackBreakThisHand(
                        ControllerType.LEFT, DOWN, true).pressed(),
                "Y routes with its logical hand before lifecycle replacement");
        state.armCooldown(InteractionHand.MAIN_HAND, 7);
        state.armCooldown(InteractionHand.OFF_HAND, 9);
        state.setExternalHeldHand(InteractionHand.MAIN_HAND);
        ExternalHandUseState.setHeld(true);

        require(state.resetForLifecycle(),
                "production reset reports the simulated attack key for release");
        require(state.cooldownReady(InteractionHand.MAIN_HAND) &&
                        state.cooldownReady(InteractionHand.OFF_HAND),
                "production reset clears both independent cooldowns");
        require(state.externalHeldHand() == null && !ExternalHandUseState.isHeld(),
                "production reset clears local and Vivecraft external-use state");
        IndependentHandUseLatch.Outcome held = state.updateUses(DOWN, true, DOWN, true);
        require(!held.mainUse() && !held.offhandUse() &&
                        !state.updateMainAttacks(DOWN, true, RELEASED, true) &&
                        !state.updateAttackBreakThisHand(
                                ControllerType.LEFT, DOWN, true).held(),
                "held B, LT use, Y, and RT remain suppressed after lifecycle replacement");

        state.updateUses(RELEASED, true, RELEASED, true);
        state.updateMainAttacks(RELEASED, true, RELEASED, true);
        state.updateAttackBreakThisHand(ControllerType.LEFT, RELEASED, true);
        IndependentHandUseLatch.Outcome fresh = state.updateUses(DOWN, true, DOWN, true);
        require(fresh.mainUse() && fresh.offhandUse() &&
                        state.updateMainAttacks(DOWN, true, RELEASED, true) &&
                        state.updateAttackBreakThisHand(
                                ControllerType.LEFT, DOWN, true).pressed(),
                "observed releases rearm all four world routes");
    }

    private static void simultaneousAndLongUsesShareTheProductionDispatcher() {
        HandTargetSnapshot main = missTarget(
                ControllerType.RIGHT, InteractionHand.MAIN_HAND, new Vec3(1.0D, 2.0D, 3.0D));
        HandTargetSnapshot offhand = missTarget(
                ControllerType.LEFT, InteractionHand.OFF_HAND, new Vec3(-1.0D, 4.0D, 2.0D));
        List<HandTargetSnapshot> dispatched = new ArrayList<>();
        PerHandUseDispatch.Outcome instant = PerHandUseDispatch.dispatch(
                false,
                new PerHandUseDispatch.Attempt<>(main, true, false, true),
                new PerHandUseDispatch.Attempt<>(offhand, true, false, true),
                target -> {
                    dispatched.add(target);
                    return false;
                });
        require(instant.mainDispatched() && instant.offhandDispatched(),
                "simultaneous instant uses both dispatch in one tick");
        require(dispatched.equals(List.of(main, offhand)),
                "prepared immutable main/right and offhand/left targets retain order");
        require(dispatched.get(0).controller() == ControllerType.RIGHT &&
                        dispatched.get(0).hand() == InteractionHand.MAIN_HAND &&
                        dispatched.get(0).start().equals(new Vec3(1.0D, 2.0D, 3.0D)) &&
                        dispatched.get(1).controller() == ControllerType.LEFT &&
                        dispatched.get(1).hand() == InteractionHand.OFF_HAND &&
                        dispatched.get(1).start().equals(new Vec3(-1.0D, 4.0D, 2.0D)),
                "dispatch cannot rebind either prepared controller ray or InteractionHand");

        dispatched.clear();
        PerHandUseDispatch.Outcome longUse = PerHandUseDispatch.dispatch(
                false,
                new PerHandUseDispatch.Attempt<>(main, true, false, true),
                new PerHandUseDispatch.Attempt<>(offhand, true, false, true),
                target -> {
                    dispatched.add(target);
                    return target == main;
                });
        require(longUse.mainDispatched() && !longUse.offhandDispatched() &&
                        longUse.blocked(),
                "main long-use start prevents a simultaneous second use");
        require(dispatched.equals(List.of(main)),
                "long use never mutates or consumes the offhand target");

        PerHandUseDispatch.Outcome continuation = PerHandUseDispatch.dispatch(
                true,
                new PerHandUseDispatch.Attempt<>(main, true, true, true),
                new PerHandUseDispatch.Attempt<>(offhand, true, false, true),
                target -> {
                    throw new AssertionError("continuation must not redispatch");
                });
        require(!continuation.mainDispatched() && !continuation.offhandDispatched(),
                "long-use continuation holds without replaying either action");
    }

    private static HandTargetSnapshot missTarget(
            ControllerType controller,
            InteractionHand hand,
            Vec3 start
    ) {
        BlockHitResult miss = BlockHitResult.miss(start, Direction.UP, BlockPos.ZERO);
        return new HandTargetSnapshot(
                controller, hand, start, new Vec3(0.0D, 0.0D, 1.0D),
                miss, null, miss);
    }

    private static void requireReplaced(
            HandActionLifecycle lifecycle,
            Object level,
            Object player,
            Object inventory,
            Object menu,
            Object gameMode,
            Object vrRuntime,
            Object vrPlayer,
            String component
    ) {
        require(lifecycle.observe(true, level, player, inventory, menu, gameMode,
                        vrRuntime, vrPlayer) == HandActionLifecycle.Transition.REPLACED,
                component + " identity replacement resets routing");
        require(lifecycle.observe(true, level, player, inventory, menu, gameMode,
                        vrRuntime, vrPlayer) == HandActionLifecycle.Transition.STABLE,
                component + " replacement stabilizes only on the next tick");
    }

    private static void explicitMainUseSuppressesSameHandAttack() {
        require(PerHandWorldActionPolicy.allowMainAttack(true, false),
                "RT attacks when B is idle");
        require(!PerHandWorldActionPolicy.allowMainAttack(true, true),
                "B main use wins an exact same-hand conflict");
        require(!PerHandWorldActionPolicy.allowMainAttack(false, false),
                "ownership gate still blocks attack");
    }

    private static void assertRoute(
            PerHandWorldActionPolicy.Command command,
            ControllerType controller,
            InteractionHand hand
    ) {
        PerHandWorldActionPolicy.Route route = PerHandWorldActionPolicy.route(command);
        require(route.controller() == controller && route.hand() == hand,
                command + " route changed");
    }

    private static void require(boolean condition, String message) {
        if (!condition) {
            throw new AssertionError(message);
        }
    }
}
