package org.questcraft.veq.client.input;

import net.minecraft.client.KeyMapping;
import net.minecraft.client.Minecraft;
import net.minecraft.client.player.LocalPlayer;
import net.minecraft.core.BlockPos;
import net.minecraft.world.InteractionHand;
import net.minecraft.world.InteractionResult;
import net.minecraft.world.entity.Entity;
import net.minecraft.world.item.ItemStack;
import net.minecraft.world.phys.BlockHitResult;
import net.minecraft.world.phys.EntityHitResult;
import net.minecraft.world.phys.HitResult;
import org.questcraft.veq.client.radial.HotbarSlotButton;
import org.questcraft.veq.client.radial.RadialHotbarController;
import org.vivecraft.api.data.VRBodyPart;
import org.vivecraft.client.VivecraftVRMod;
import org.vivecraft.client.network.ClientNetworking;
import org.vivecraft.client_vr.ClientDataHolderVR;
import org.vivecraft.client_vr.VRState;
import org.vivecraft.client_vr.gameplay.ClientHandActionTickGuard;
import org.vivecraft.client_vr.gameplay.ScopedUseItemOnContext;
import org.vivecraft.client_vr.provider.ControllerType;
import org.vivecraft.client_vr.provider.ExternalHandUseState;
import org.vivecraft.client_vr.provider.openvr_lwjgl.VRInputAction;
import org.vivecraft.client_vr.render.VRFirstPersonArmSwing;
import org.vivecraft.client_vr.settings.VRSettings;
import org.vivecraft.mixin.client_vr.multiplayer.MultiPlayerGameModeAccessor;

import java.util.function.Supplier;

/**
 * Quest personal world controls with one logical mapping boundary:
 * RT attacks from logical RIGHT, LT uses logical LEFT/OFF_HAND, and physical
 * right B uses logical RIGHT/MAIN_HAND. OpenXR alone applies reverseHands.
 */
public final class PerHandWorldActionRouter {
    private static final PerHandWorldActionPolicy.Route MAIN_ATTACK =
            PerHandWorldActionPolicy.route(PerHandWorldActionPolicy.Command.MAIN_ATTACK);
    private static final PerHandWorldActionPolicy.Route MAIN_USE =
            PerHandWorldActionPolicy.route(PerHandWorldActionPolicy.Command.MAIN_USE_BUTTON);
    private static final PerHandWorldActionPolicy.Route OFFHAND_USE =
            PerHandWorldActionPolicy.route(PerHandWorldActionPolicy.Command.OFFHAND_TRIGGER_USE);
    private static final PerHandWorldActionPolicy.Route OFFHAND_ATTACK =
            PerHandWorldActionPolicy.route(PerHandWorldActionPolicy.Command.OFFHAND_ATTACK);

    private final PerHandTransientState transientState = new PerHandTransientState();
    private final HandActionLifecycle lifecycle = new HandActionLifecycle();

    public void tick(Minecraft minecraft) {
        ImmersiveAttackState.beginFrame();
        this.transientState.tickCooldowns();
        HotbarSlotButton.reconcilePending(minecraft);
        GripRuntimeGate.pollReleaseGates();
        if (!VRState.VR_RUNNING) {
            clearForVrShutdown(minecraft);
            return;
        }

        ClientDataHolderVR dataHolder = ClientDataHolderVR.getInstance();
        VRInputAction offhandUseAction = inputAction(
                dataHolder, VivecraftVRMod.INSTANCE.keyOffhandUse);
        // Legacy core symbol; v67 interprets this one physical-B action as
        // MAIN_HAND use without changing the Vivecraft-core ABI.
        VRInputAction mainUseButtonAction = inputAction(
                dataHolder, VivecraftVRMod.INSTANCE.keyOffhandUseButton);
        VRInputAction mainAttackAction = inputAction(
                dataHolder, VivecraftVRMod.INSTANCE.keyMainAttack);
        VRInputAction attackBreakThisHandAction = inputAction(
                dataHolder, QuestButtonKeyMappings.attackBreakThisHandButton());

        LeftUseCapture.Sample offhandSample = sampleHandedAction(
                dataHolder, offhandUseAction, OFFHAND_USE.controller());
        this.transientState.observeMenuBlockAttempt(
                offhandSample, minecraft.gui.screen());
        HandedActionSample mainUseSample = sampleBoundHandedAction(
                dataHolder, mainUseButtonAction);
        LeftUseCapture.Sample mainAttackTriggerSample = sampleHandedAction(
                dataHolder, mainAttackAction, MAIN_ATTACK.controller());
        HandedActionSample attackBreakThisHandSample = sampleBoundHandedAction(
                dataHolder, attackBreakThisHandAction);

        PerHandWorldActionPolicy.Route sampledAttackBreakRoute =
                PerHandWorldActionPolicy.attackBreakThisHand(
                        attackBreakThisHandSample.controller());

        HandOwnershipSnapshot ownership = HandOwnershipSnapshot.capture(minecraft, dataHolder);
        HandActionLifecycle.Transition lifecycleTransition = this.lifecycle.observe(
                ownership.runtimeReady(),
                minecraft.level,
                minecraft.player,
                minecraft.player == null ? null : minecraft.player.getInventory(),
                minecraft.player == null ? null : minecraft.player.inventoryMenu,
                minecraft.gameMode,
                dataHolder.vr,
                dataHolder.vrPlayer);
        if (lifecycleTransition.requiresReset()) {
            resetTransientState(minecraft);
        }
        boolean lifecycleAllowsRouting = lifecycleTransition.allowsRouting();
        if (!lifecycleAllowsRouting) {
            ImmersiveAttackState.clear();
        } else {
            // ImmersiveMC reads one Vanilla attack key for both hands. Feed it
            // a Quest RT/Y sample only after this tick's ownership snapshot
            // proves that the matching logical hand belongs to ImmersiveMC.
            // All other owners explicitly suppress that hand in the bridge.
            observeImmersiveAttack(
                    ownership, MAIN_ATTACK.controller(), MAIN_ATTACK.hand(),
                    mainAttackTriggerSample);
            if (sampledAttackBreakRoute != null) {
                observeImmersiveAttack(
                        ownership,
                        sampledAttackBreakRoute.controller(),
                        sampledAttackBreakRoute.hand(),
                        attackBreakThisHandSample.sample());
            }
        }

        HandOwnershipSnapshot.HandState mainState = ownership.hand(MAIN_USE.controller());
        HandOwnershipSnapshot.HandState offhandState = ownership.hand(OFFHAND_USE.controller());
        HandOwnershipSnapshot.HandState mainUseSourceState =
                ownership.hand(mainUseSample.controller());
        boolean mainContinuing = isContinuingExternalUse(minecraft.player, MAIN_USE.hand());
        boolean offhandContinuing = isContinuingExternalUse(minecraft.player, OFFHAND_USE.hand());

        boolean mainTargetAllowed = lifecycleAllowsRouting && actionWorldAllowed(
                ownership, mainState, minecraft.player, MAIN_USE.hand(), mainContinuing);
        boolean mainSourceAllowed = lifecycleAllowsRouting && mainUseSourceState != null &&
                mainUseSourceState.worldAllowed(
                        ownership.runtimeReady(), ownership.bowOwnsBothHands());
        boolean mainInputEnabled = mainUseButtonAction != null &&
                mainUseSample.controller() != null &&
                mainUseButtonAction.isEnabled(mainUseSample.controller());
        boolean mainUseAllowed = PerHandWorldActionPolicy.allowBoundMainUse(
                mainTargetAllowed, mainSourceAllowed, mainInputEnabled);
        boolean offhandWorldAllowed = lifecycleAllowsRouting && actionWorldAllowed(
                ownership, offhandState, minecraft.player, OFFHAND_USE.hand(), offhandContinuing) &&
                offhandUseAction != null && offhandUseAction.isEnabled(OFFHAND_USE.controller());
        boolean playerCanStartUse = minecraft.player != null && !minecraft.player.isUsingItem();
        // LT is always logical-left OFF_HAND use/place. It never changes into
        // melee based on the held item or target.
        boolean offhandUseAllowed = offhandWorldAllowed;
        this.transientState.observeOffhandOwnership(offhandUseAllowed, offhandSample);
        IndependentHandUseLatch.Outcome uses = this.transientState.updateUses(
                mainUseSample.sample(), mainUseAllowed,
                offhandSample, offhandUseAllowed);

        boolean mainAttackTargetAllowed = lifecycleAllowsRouting && actionWorldAllowed(
                ownership, mainState, minecraft.player, MAIN_ATTACK.hand(), false);
        boolean mainAttackTriggerAllowed = mainAttackTargetAllowed &&
                mainAttackAction != null &&
                mainAttackAction.isEnabled(MAIN_ATTACK.controller());
        boolean attackShouldRoute = this.transientState.updateMainAttacks(
                mainAttackTriggerSample,
                PerHandWorldActionPolicy.allowMainAttack(
                        mainAttackTriggerAllowed, uses.mainUse()),
                LeftUseCapture.Sample.RELEASED,
                false
        );
        HandTargetSnapshot mainAttackTarget = captureMainAttackTarget(
                minecraft, mainState, attackShouldRoute);

        PerHandWorldActionPolicy.Route attackBreakRoute = sampledAttackBreakRoute;
        HandOwnershipSnapshot.HandState attackBreakState = attackBreakRoute == null
                ? null
                : ownership.hand(attackBreakRoute.controller());
        boolean attackBreakWorldAllowed = attackBreakRoute != null &&
                lifecycleAllowsRouting &&
                actionWorldAllowed(
                        ownership, attackBreakState, minecraft.player,
                        attackBreakRoute.hand(), false) &&
                attackBreakThisHandAction != null &&
                attackBreakThisHandAction.isEnabled(attackBreakRoute.controller()) &&
                attackBreakUseChannelFree(
                        attackBreakRoute.hand(), uses.mainUse(), uses.offhandUse());
        boolean attackBreakAllowed = attackBreakRoute != null &&
                PerHandWorldActionPolicy.allowAttackBreakThisHand(
                        attackBreakRoute.hand(), attackBreakWorldAllowed,
                        ClientNetworking.supportsOffhandAttackRouting());
        AttackBreakThisHandLatch.Outcome attackBreakOutcome =
                this.transientState.updateAttackBreakThisHand(
                        attackBreakThisHandSample.controller(),
                        attackBreakThisHandSample.sample(),
                        attackBreakAllowed);
        HandTargetSnapshot attackBreakTarget = captureAttackTarget(
                minecraft, attackBreakState, attackBreakRoute,
                attackBreakOutcome.held());
        ButtonMiningFrame miningFrame = coordinateButtonMiningIntents(
                minecraft, mainAttackTarget, attackBreakRoute, attackBreakTarget);
        boolean nativeBlockIntent = miningFrame.nativeTarget() != null;
        routeMainAttack(
                minecraft,
                mainAttackTarget,
                attackShouldRoute && (!nativeBlockIntent ||
                        miningFrame.plan().routeNativeMain()),
                !nativeBlockIntent || miningFrame.plan().synthesizeNativePress());
        if (attackBreakOutcome.held() && attackBreakEntityDispatchAllowed(
                attackBreakRoute.hand(), attackShouldRoute)) {
            dispatchAttackBreakEntity(
                    minecraft, dataHolder, attackBreakRoute, attackBreakTarget,
                    attackBreakOutcome.pressed());
        }
        if (miningFrame.plan().hasCustomMiningDriver()) {
            dispatchCoordinatedButtonMining(
                    minecraft, dataHolder, miningFrame, mainAttackTarget,
                    attackBreakRoute, attackBreakTarget,
                    attackBreakOutcome.pressed());
        }

        boolean continuing = (mainContinuing && uses.mainUse()) ||
                (offhandContinuing && uses.offhandUse());
        ExternalHandUseState.setHeld(continuing);
        HandTargetSnapshot mainTarget = captureUseTarget(
                minecraft, minecraft.player, mainState, MAIN_USE.hand(),
                playerCanStartUse && uses.mainUse() && !mainContinuing &&
                        this.transientState.cooldownReady(MAIN_USE.hand()));
        HandTargetSnapshot offhandTarget = captureUseTarget(
                minecraft, minecraft.player, offhandState, OFFHAND_USE.hand(),
                playerCanStartUse && uses.offhandUse() && !offhandContinuing &&
                        this.transientState.cooldownReady(OFFHAND_USE.hand()));
        int useDelay = useDelay(dataHolder.vrSettings.rightclickDelay);
        PerHandUseDispatch.dispatch(
                !playerCanStartUse,
                new PerHandUseDispatch.Attempt<>(
                        mainTarget, uses.mainUse(), mainContinuing,
                        this.transientState.cooldownReady(MAIN_USE.hand())),
                new PerHandUseDispatch.Attempt<>(
                        offhandTarget, uses.offhandUse(), offhandContinuing,
                        this.transientState.cooldownReady(OFFHAND_USE.hand())),
                target -> {
                    if (!dispatchUse(minecraft, dataHolder, target)) {
                        return false;
                    }
                    this.transientState.armCooldown(target.hand(), useDelay);
                    return minecraft.player == null || minecraft.level == null ||
                            minecraft.gui.screen() != null || minecraft.player.isUsingItem();
                });
        updateExternalContinuation(minecraft.player, uses);
    }

    static int useDelay(VRSettings.RightClickDelay delay) {
        return switch (delay) {
            case VANILLA -> 4;
            case SLOW -> 6;
            case SLOWER -> 8;
            case SLOWEST -> 10;
        };
    }

    private static VRInputAction inputAction(
            ClientDataHolderVR dataHolder,
            KeyMapping key
    ) {
        return dataHolder.vr == null || key == null ? null : dataHolder.vr.getInputAction(key);
    }

    private static boolean actionWorldAllowed(
            HandOwnershipSnapshot ownership,
            HandOwnershipSnapshot.HandState state,
            LocalPlayer player,
            InteractionHand hand,
            boolean continuingThisUse
    ) {
        if (player == null || state == null || !state.worldAllowed(
                ownership.runtimeReady(), ownership.bowOwnsBothHands())) {
            return false;
        }
        if (!player.isHandsBusy() && !player.isUsingItem()) {
            return true;
        }
        return continuingThisUse && player.isUsingItem() && player.getUsedItemHand() == hand;
    }

    private static HandTargetSnapshot captureMainAttackTarget(
            Minecraft minecraft,
            HandOwnershipSnapshot.HandState mainState,
            boolean attackShouldRoute
    ) {
        if (!attackShouldRoute || minecraft.player == null ||
                mainState == null || mainState.aimPose() == null) {
            return null;
        }
        return HandTargetSnapshot.capture(
                minecraft, minecraft.player, mainState, MAIN_ATTACK.hand(), false);
    }

    private void routeMainAttack(
            Minecraft minecraft,
            HandTargetSnapshot target,
            boolean route,
            boolean synthesizePress
    ) {
        if (!route || target == null) {
            releaseMainAttack(minecraft);
            return;
        }

        // Vanilla startAttack/continueAttack consumes one global target later
        // in this same client tick. A rejoining RT on an already-active
        // coordinated session sets the held state without synthesizing a new
        // click, so it cannot emit another START for the same block.
        minecraft.hitResult = target.primaryHit();
        if (this.transientState.beginMainAttack()) {
            if (synthesizePress) {
                VRInputAction.setKeyBindState(minecraft.options.keyAttack, true);
            } else {
                minecraft.options.keyAttack.setDown(true);
            }
        } else {
            minecraft.options.keyAttack.setDown(true);
        }
    }

    private void releaseMainAttack(Minecraft minecraft) {
        if (this.transientState.releaseMainAttack()) {
            minecraft.options.keyAttack.setDown(false);
        }
    }

    private static HandTargetSnapshot captureAttackTarget(
            Minecraft minecraft,
            HandOwnershipSnapshot.HandState state,
            PerHandWorldActionPolicy.Route route,
            boolean held
    ) {
        if (!held || minecraft.player == null || minecraft.level == null ||
                minecraft.gameMode == null || state == null || route == null ||
                state.aimPose() == null) {
            return null;
        }
        return HandTargetSnapshot.capture(
                minecraft, minecraft.player, state, route.hand(), false);
    }

    private static ButtonMiningFrame coordinateButtonMiningIntents(
            Minecraft minecraft,
            HandTargetSnapshot mainAttackTarget,
            PerHandWorldActionPolicy.Route attackBreakRoute,
            HandTargetSnapshot attackBreakTarget
    ) {
        if (minecraft.level == null || minecraft.player == null || minecraft.gameMode == null) {
            return ButtonMiningFrame.NONE;
        }

        // Keep native RT and routed Y as separate input sources. With
        // reverseHands, physical-left Y can legitimately resolve to logical
        // MAIN_HAND, but it still is not the native RT path that Vanilla will
        // process later in this tick.
        BlockPos nativeMainTarget = validMiningTarget(minecraft, mainAttackTarget);
        BlockPos routedTarget = validMiningTarget(minecraft, attackBreakTarget);
        VRBodyPart routedBodyPart = attackBreakRoute == null
                ? null
                : VRBodyPart.fromInteractionHand(attackBreakRoute.hand());
        boolean destroying = minecraft.gameMode.isDestroying();
        BlockPos currentDestroyTarget = destroying
                ? ((MultiPlayerGameModeAccessor) minecraft.gameMode)
                        .vivecraft$getDestroyBlockPos()
                : null;
        ClientHandActionTickGuard guard = ClientHandActionTickGuard.global();
        ClientHandActionTickGuard.ButtonMiningPlan plan =
                guard.coordinateButtonMiningIntents(
                        minecraft.level,
                        minecraft.level.getGameTime(),
                        nativeMainTarget,
                        routedBodyPart,
                        routedTarget,
                        destroying,
                        currentDestroyTarget);
        return new ButtonMiningFrame(nativeMainTarget, routedTarget, plan);
    }

    private static BlockPos validMiningTarget(
            Minecraft minecraft,
            HandTargetSnapshot target
    ) {
        if (target == null ||
                !(target.primaryHit() instanceof BlockHitResult blockHit) ||
                !isMineableBlockHit(blockHit,
                        minecraft.level.getBlockState(blockHit.getBlockPos()).isAir()) ||
                !minecraft.player.isWithinBlockInteractionRange(
                        blockHit.getBlockPos(), 0.0D) ||
                !minecraft.level.getWorldBorder().isWithinBounds(blockHit.getBlockPos())) {
            return null;
        }
        return blockHit.getBlockPos().immutable();
    }

    static boolean isMineableBlockHit(BlockHitResult hit, boolean air) {
        return hit != null && hit.getType() == HitResult.Type.BLOCK && !air;
    }

    /**
     * Keeps a routed Y press captured while RT owns the same logical main hand.
     * The mining coordinator needs that held intent for a release handoff;
     * only a simultaneous use action owns and suppresses the hand completely.
     */
    static boolean attackBreakUseChannelFree(
            InteractionHand hand,
            boolean mainUseRouted,
            boolean offhandUseRouted
    ) {
        return hand == InteractionHand.MAIN_HAND
                ? !mainUseRouted
                : !offhandUseRouted;
    }

    /** Prevents RT and routed logical-main Y from attacking one entity twice. */
    static boolean attackBreakEntityDispatchAllowed(
            InteractionHand routedHand,
            boolean mainAttackRouted
    ) {
        return routedHand != InteractionHand.MAIN_HAND || !mainAttackRouted;
    }

    private static void dispatchAttackBreakEntity(
            Minecraft minecraft,
            ClientDataHolderVR dataHolder,
            PerHandWorldActionPolicy.Route route,
            HandTargetSnapshot target,
            boolean pressed
    ) {
        if (minecraft.player == null || minecraft.level == null ||
                minecraft.gameMode == null || route == null || target == null) {
            return;
        }

        ItemStack stack = minecraft.player.getItemInHand(route.hand());
        if (!stack.isItemEnabled(minecraft.level.enabledFeatures())) {
            return;
        }
        VRBodyPart bodyPart = VRBodyPart.fromInteractionHand(route.hand());
        long tick = minecraft.level.getGameTime();

        if (!(target.primaryHit() instanceof EntityHitResult entityHit)) {
            return;
        }
        Entity entity = entityHit.getEntity();
        if (!pressed || minecraft.gameMode.isSpectator() || !entity.isAttackable() ||
                !minecraft.level.getWorldBorder().isWithinBounds(entity.blockPosition()) ||
                !minecraft.player.isWithinAttackRange(
                        stack, entity.getBoundingBox(), 0.0D) ||
                ClientNetworking.cannotAttackWithItemForBodyPart(
                        minecraft.player, bodyPart, stack, 0) ||
                !ClientHandActionTickGuard.global().claimEntityAttack(
                        minecraft.level, tick, bodyPart, entity.getId())) {
            return;
        }
        runWithBodyPart(route.hand(), () -> {
            minecraft.gameMode.attack(minecraft.player, entity);
            dataHolder.swingType = VRFirstPersonArmSwing.ATTACK;
            minecraft.player.swing(route.hand());
            dataHolder.vr.triggerHapticPulse(
                    QuestHandMapping.hapticController(route.controller()),
                    0.025F, 160.0F, 0.35F);
        });
    }

    private static void dispatchCoordinatedButtonMining(
            Minecraft minecraft,
            ClientDataHolderVR dataHolder,
            ButtonMiningFrame frame,
            HandTargetSnapshot nativeMainTarget,
            PerHandWorldActionPolicy.Route routedRoute,
            HandTargetSnapshot routedTarget,
            boolean routedPressed
    ) {
        ClientHandActionTickGuard.ButtonMiningPlan plan = frame.plan();
        HandTargetSnapshot driverTarget =
                plan.customTargetSource() ==
                        ClientHandActionTickGuard.ButtonMiningInput.NATIVE_MAIN
                        ? nativeMainTarget
                        : routedTarget;
        ControllerType driverController =
                plan.customTargetSource() ==
                        ClientHandActionTickGuard.ButtonMiningInput.NATIVE_MAIN
                        ? MAIN_ATTACK.controller()
                        : routedRoute == null ? null : routedRoute.controller();
        InteractionHand ownerHand = interactionHand(plan.sessionOwner());
        if (minecraft.player == null || minecraft.level == null ||
                minecraft.gameMode == null || driverTarget == null ||
                driverController == null || ownerHand == null ||
                !(driverTarget.primaryHit() instanceof BlockHitResult blockHit) ||
                !isMineableBlockHit(blockHit,
                        minecraft.level.getBlockState(blockHit.getBlockPos()).isAir()) ||
                !minecraft.player.isWithinBlockInteractionRange(
                        blockHit.getBlockPos(), 0.0D) ||
                !minecraft.level.getWorldBorder().isWithinBounds(blockHit.getBlockPos())) {
            return;
        }

        ItemStack ownerStack = minecraft.player.getItemInHand(ownerHand);
        if (!ownerStack.isItemEnabled(minecraft.level.enabledFeatures())) {
            return;
        }

        runWithBodyPart(ownerHand, () -> {
            if (plan.routedDecision() == ClientHandActionTickGuard.MiningDecision.START) {
                boolean started = minecraft.gameMode.startDestroyBlock(
                        blockHit.getBlockPos(), blockHit.getDirection());
                // Match Vanilla's startAttack + continueAttack cadence once.
                // This is one selected source, not an additive second-hand hit.
                if (started && minecraft.gameMode.isDestroying() &&
                        minecraft.gameMode.continueDestroyBlock(
                                blockHit.getBlockPos(), blockHit.getDirection())) {
                    minecraft.level.addBreakingBlockEffect(
                            blockHit.getBlockPos(), blockHit.getDirection());
                }
            } else if (minecraft.gameMode.continueDestroyBlock(
                    blockHit.getBlockPos(), blockHit.getDirection())) {
                minecraft.level.addBreakingBlockEffect(
                        blockHit.getBlockPos(), blockHit.getDirection());
            }
            if ((plan.customTargetSource() ==
                    ClientHandActionTickGuard.ButtonMiningInput.ROUTED && routedPressed) ||
                    plan.routedDecision() == ClientHandActionTickGuard.MiningDecision.START) {
                dataHolder.swingType = VRFirstPersonArmSwing.ATTACK;
                minecraft.player.swing(ownerHand);
                dataHolder.vr.triggerHapticPulse(
                        QuestHandMapping.hapticController(driverController),
                        0.025F, 160.0F, 0.25F);
            }
        });
        if (!minecraft.gameMode.isDestroying()) {
            ClientHandActionTickGuard.global().finishButtonMiningSession(
                    minecraft.level, blockHit.getBlockPos());
        }
    }

    private static InteractionHand interactionHand(VRBodyPart bodyPart) {
        return bodyPart == VRBodyPart.MAIN_HAND
                ? InteractionHand.MAIN_HAND
                : bodyPart == VRBodyPart.OFF_HAND
                        ? InteractionHand.OFF_HAND
                        : null;
    }

    private static void runWithBodyPart(InteractionHand hand, Runnable action) {
        VRBodyPart previousOverride = ClientNetworking.BODY_PART_CLIENT_OVERRIDE;
        try {
            ClientNetworking.BODY_PART_CLIENT_OVERRIDE = VRBodyPart.fromInteractionHand(hand);
            ClientNetworking.sendActiveHand(hand, true);
            action.run();
        } finally {
            ClientNetworking.BODY_PART_CLIENT_OVERRIDE = previousOverride;
            ClientNetworking.resetActiveBodyPart();
        }
    }

    private static HandTargetSnapshot captureUseTarget(
            Minecraft minecraft,
            LocalPlayer player,
            HandOwnershipSnapshot.HandState state,
            InteractionHand hand,
            boolean eligible
    ) {
        if (!eligible || player == null || minecraft.level == null || state == null ||
                state.aimPose() == null) {
            return null;
        }
        return HandTargetSnapshot.capture(minecraft, player, state, hand, true);
    }

    private boolean dispatchUse(
            Minecraft minecraft,
            ClientDataHolderVR dataHolder,
            HandTargetSnapshot target
    ) {
        if (minecraft.player == null || minecraft.level == null) {
            return false;
        }
        InteractionHand blockInteractionHand = prepareBlockInteractionHand(
                minecraft, minecraft.player, target);
        if (blockInteractionHand == null) {
            // The translated menu attempt was already consumed by this held
            // L2 press. Do not emit another active-hand or use packet and do
            // not rearm the ordinary right-click cooldown.
            return false;
        }
        try {
            ClientNetworking.sendActiveHand(target.hand(), true);
            useTarget(minecraft, minecraft.player, dataHolder, target,
                    blockInteractionHand);
            if (minecraft.player.isUsingItem() &&
                    minecraft.player.getUsedItemHand() == target.hand()) {
                this.transientState.setExternalHeldHand(target.hand());
            }
            return true;
        } finally {
            ClientNetworking.resetActiveBodyPart();
        }
    }

    /**
     * Resolves the sole block-only hand translation before any network side
     * effect. A null result means the held-L2 one-shot guard rejected a retry.
     */
    private InteractionHand prepareBlockInteractionHand(
            Minecraft minecraft,
            LocalPlayer player,
            HandTargetSnapshot target
    ) {
        InteractionHand requestedHand = target.hand();
        if (target.primaryHit() instanceof EntityHitResult ||
                target.blockHit().getType() != HitResult.Type.BLOCK ||
                requestedHand != InteractionHand.OFF_HAND ||
                player.isSecondaryUseActive()) {
            return requestedHand;
        }

        if (!player.isWithinBlockInteractionRange(
                target.blockHit().getBlockPos(), 0.0D) ||
                !minecraft.level.getWorldBorder().isWithinBounds(
                        target.blockHit().getBlockPos())) {
            return requestedHand;
        }

        boolean menuTarget = minecraft.level.getBlockState(
                target.blockHit().getBlockPos()).getMenuProvider(
                minecraft.level, target.blockHit().getBlockPos()) != null;
        InteractionHand interactionHand =
                PerHandWorldActionPolicy.interactionHandForBlockMenu(
                        requestedHand, false, menuTarget);
        if (interactionHand != requestedHand &&
                !this.transientState.claimMenuBlockAttempt()) {
            return null;
        }
        return interactionHand;
    }

    private void useTarget(
            Minecraft minecraft,
            LocalPlayer player,
            ClientDataHolderVR dataHolder,
            HandTargetSnapshot target,
            InteractionHand blockInteractionHand
    ) {
        InteractionHand hand = target.hand();
        ItemStack stack = player.getItemInHand(hand);
        if (!stack.isItemEnabled(minecraft.level.enabledFeatures())) {
            return;
        }

        if (target.primaryHit() instanceof EntityHitResult entityHit) {
            Entity entity = entityHit.getEntity();
            PerHandWorldActionPolicy.EntityUseDecision entityDecision =
                    PerHandWorldActionPolicy.entityUseDecision(
                            minecraft.level.getWorldBorder().isWithinBounds(
                                    entity.blockPosition()),
                            player.isWithinEntityInteractionRange(entity, 0.0D));
            if (entityDecision == PerHandWorldActionPolicy.EntityUseDecision.STOP) {
                return;
            }
            if (entityDecision == PerHandWorldActionPolicy.EntityUseDecision.INTERACT) {
                InteractionHand interactionHand =
                        PerHandWorldActionPolicy.interactionHandForEntity(hand);
                InteractionResult entityResult = minecraft.gameMode.interact(
                        player, entity, entityHit, interactionHand);
                if (entityResult instanceof InteractionResult.Success success) {
                    swingIfRequested(player, hand, target.controller(), success, dataHolder);
                    return;
                }
            }
            useHeldItem(minecraft, player, hand, target.controller(), dataHolder, stack);
            return;
        }

        boolean blockTarget = target.blockHit().getType() == HitResult.Type.BLOCK;
        PerHandWorldActionPolicy.BlockUseDecision blockDecision =
                PerHandWorldActionPolicy.blockUseDecision(
                        blockTarget,
                        blockTarget && player.isWithinBlockInteractionRange(
                                target.blockHit().getBlockPos(), 0.0D),
                        blockTarget && minecraft.level.getWorldBorder().isWithinBounds(
                                target.blockHit().getBlockPos()));
        if (blockDecision == PerHandWorldActionPolicy.BlockUseDecision.STOP) {
            return;
        }
        if (blockDecision == PerHandWorldActionPolicy.BlockUseDecision.USE_BLOCK) {
            int oldCount = stack.getCount();
            InteractionResult blockResult = withBlockInteractionContext(
                    target, blockInteractionHand,
                    () -> minecraft.gameMode.useItemOn(
                            player, blockInteractionHand, target.blockHit()));
            if (blockResult instanceof InteractionResult.Success success) {
                swingIfRequested(player, hand, target.controller(), success, dataHolder);
                if (!stack.isEmpty() &&
                        (stack.getCount() != oldCount || player.hasInfiniteMaterials())) {
                    minecraft.gameRenderer.itemInHandRenderer.itemUsed(hand);
                }
                return;
            }
            if (blockResult instanceof InteractionResult.Fail || blockInteractionHand != hand) {
                return;
            }
        }

        useHeldItem(minecraft, player, hand, target.controller(), dataHolder, stack);
    }

    static <T> T withBlockInteractionContext(
            HandTargetSnapshot target,
            InteractionHand protocolHand,
            Supplier<T> interaction
    ) {
        if (protocolHand == target.hand()) {
            return interaction.get();
        }
        // MAIN_HAND is only a protocol compatibility translation. The
        // immutable logical-left ray remains authoritative for the look
        // override and is always removed, including exceptions.
        try (ScopedUseItemOnContext.Scope ignored =
                     ScopedUseItemOnContext.openTranslatedLeft(
                             target.controller(), target.start(),
                             target.direction(), target.blockHit())) {
            return interaction.get();
        }
    }

    private static void useHeldItem(
            Minecraft minecraft,
            LocalPlayer player,
            InteractionHand hand,
            ControllerType controller,
            ClientDataHolderVR dataHolder,
            ItemStack stack
    ) {
        if (stack.isEmpty()) {
            return;
        }
        InteractionResult itemResult = minecraft.gameMode.useItem(player, hand);
        if (itemResult instanceof InteractionResult.Success success) {
            swingIfRequested(player, hand, controller, success, dataHolder);
            minecraft.gameRenderer.itemInHandRenderer.itemUsed(hand);
        }
    }

    private static void swingIfRequested(
            LocalPlayer player,
            InteractionHand hand,
            ControllerType controller,
            InteractionResult.Success success,
            ClientDataHolderVR dataHolder
    ) {
        if (success.swingSource() == InteractionResult.SwingSource.CLIENT) {
            dataHolder.swingType = VRFirstPersonArmSwing.USE;
            player.swing(hand);
            dataHolder.vr.triggerHapticPulse(
                    QuestHandMapping.hapticController(controller), 0.025F, 160.0F, 0.35F);
        }
    }

    private boolean isContinuingExternalUse(LocalPlayer player, InteractionHand hand) {
        return player != null && this.transientState.externalHeldHand() == hand &&
                player.isUsingItem() &&
                player.getUsedItemHand() == hand;
    }

    private void updateExternalContinuation(
            LocalPlayer player,
            IndependentHandUseLatch.Outcome uses
    ) {
        if (player == null || !player.isUsingItem()) {
            this.transientState.clearExternalHeldHand();
        } else if (player.getUsedItemHand() == InteractionHand.MAIN_HAND && !uses.mainUse()) {
            this.transientState.clearExternalHeldHand();
        } else if (player.getUsedItemHand() == InteractionHand.OFF_HAND && !uses.offhandUse()) {
            this.transientState.clearExternalHeldHand();
        }
        ExternalHandUseState.setHeld(this.transientState.externalHeldHand() != null);
    }

    private static LeftUseCapture.Sample sampleHandedAction(
            ClientDataHolderVR dataHolder,
            VRInputAction action,
            ControllerType controller
    ) {
        if (dataHolder.vr == null || action == null || !action.isHanded() ||
                !action.isEnabledRaw(controller) || !action.isActive(controller)) {
            return LeftUseCapture.Sample.UNKNOWN;
        }
        long origin = action.getLastOrigin(controller);
        if (origin == 0L || dataHolder.vr.getOriginControllerType(origin) != controller) {
            return LeftUseCapture.Sample.UNKNOWN;
        }
        return action.isButtonPressed(controller)
                ? LeftUseCapture.Sample.DOWN
                : LeftUseCapture.Sample.RELEASED;
    }

    /** Samples physical right B after the provider maps its origin exactly once. */
    private static HandedActionSample sampleBoundHandedAction(
            ClientDataHolderVR dataHolder,
            VRInputAction action
    ) {
        if (dataHolder.vr == null || action == null || !action.isHanded()) {
            return HandedActionSample.unknown();
        }
        HandedActionSample released = null;
        for (ControllerType controller : ControllerType.values()) {
            if (!action.isEnabledRaw(controller) || !action.isActive(controller)) {
                continue;
            }
            long origin = action.getLastOrigin(controller);
            if (origin == 0L || dataHolder.vr.getOriginControllerType(origin) != controller) {
                continue;
            }
            HandedActionSample sample = new HandedActionSample(
                    controller,
                    action.isButtonPressed(controller)
                            ? LeftUseCapture.Sample.DOWN
                            : LeftUseCapture.Sample.RELEASED);
            if (sample.sample() == LeftUseCapture.Sample.DOWN) {
                return sample;
            }
            released = sample;
        }
        return released == null ? HandedActionSample.unknown() : released;
    }

    public void clearForVrShutdown(Minecraft minecraft) {
        this.lifecycle.deactivate();
        resetTransientState(minecraft);
        GripRuntimeGate.clearForVrShutdown();
        RadialHotbarController.cancel();
    }

    private void resetTransientState(Minecraft minecraft) {
        ClientHandActionTickGuard.global().reset();
        ImmersiveAttackState.clear();
        if (this.transientState.resetForLifecycle()) {
            minecraft.options.keyAttack.setDown(false);
        }
    }

    private static void observeImmersiveAttack(
            HandOwnershipSnapshot ownership,
            ControllerType controller,
            InteractionHand hand,
            LeftUseCapture.Sample sample
    ) {
        HandOwnershipSnapshot.HandState state = ownership.hand(controller);
        if (state == null || !state.tracking() || state.aimPose() == null ||
                QuestHandMapping.interactionHand(controller) != hand) {
            // A known invalid/mismatched hand is not an optional-bridge ABI
            // miss. Force it released so resolve() cannot fall back to the
            // other controller's shared Vanilla keyAttack state.
            ImmersiveAttackState.suppress(hand);
            return;
        }
        ImmersiveAttackState.observe(hand, sample, state.owner());
    }

    private record ButtonMiningFrame(
            BlockPos nativeTarget,
            BlockPos routedTarget,
            ClientHandActionTickGuard.ButtonMiningPlan plan
    ) {
        private static final ButtonMiningFrame NONE = new ButtonMiningFrame(
                null, null, ClientHandActionTickGuard.ButtonMiningPlan.NONE);
    }

    private record HandedActionSample(
            ControllerType controller,
            LeftUseCapture.Sample sample
    ) {
        private static HandedActionSample unknown() {
            return new HandedActionSample(null, LeftUseCapture.Sample.UNKNOWN);
        }
    }
}
