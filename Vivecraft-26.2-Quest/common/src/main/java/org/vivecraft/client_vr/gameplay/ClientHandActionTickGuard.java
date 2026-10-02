package org.vivecraft.client_vr.gameplay;

import net.minecraft.core.BlockPos;
import org.vivecraft.api.data.VRBodyPart;

import java.util.Arrays;

/**
 * Client-thread guard shared by button and room-scale attacks.
 *
 * <p>Vanilla has exactly one block-destroy session and its player-action
 * packets do not identify a hand. This guard therefore elects one mining
 * driver/source for a tick. The other held hand may keep that same target alive,
 * but it never becomes a second source. A different target fails closed so
 * the client cannot alternate START/ABORT packets between two blocks.</p>
 */
public final class ClientHandActionTickGuard {
    private static final int TRACKED_BODY_PARTS = 4;
    private static final int MAX_ENTITY_TARGETS_PER_PART = 32;
    private static final ClientHandActionTickGuard GLOBAL = new ClientHandActionTickGuard();

    private final int[][] entityTargets =
        new int[TRACKED_BODY_PARTS][MAX_ENTITY_TARGETS_PER_PART];
    private final int[] entityTargetCounts = new int[TRACKED_BODY_PARTS];
    private final BlockPos[] buttonMiningTargets = new BlockPos[2];

    private Object worldIdentity;
    private long tick = Long.MIN_VALUE;
    private BlockPos miningTargetThisTick;
    private boolean miningSourceClaimed;
    private boolean buttonMiningFrameObserved;
    private BlockPos buttonMiningSessionTarget;
    private VRBodyPart buttonMiningSessionOwner;
    private ButtonMiningInput buttonMiningSessionSource = ButtonMiningInput.NONE;

    public static ClientHandActionTickGuard global() {
        return GLOBAL;
    }

    /** Returns false when this body part already attacked this entity this tick. */
    public boolean claimEntityAttack(
        Object worldIdentity, long tick, VRBodyPart bodyPart, int entityId)
    {
        int index = trackedIndex(bodyPart);
        if (worldIdentity == null || index < 0) {
            return false;
        }
        advance(worldIdentity, tick);
        int count = this.entityTargetCounts[index];
        for (int i = 0; i < count; i++) {
            if (this.entityTargets[index][i] == entityId) {
                return false;
            }
        }
        if (count == MAX_ENTITY_TARGETS_PER_PART) {
            return false;
        }
        this.entityTargets[index][count] = entityId;
        this.entityTargetCounts[index] = count + 1;
        return true;
    }

    /**
     * Claims the sole room-scale mining source for this tick.
     *
     * @param currentDestroyTarget exact target of Vanilla's active destroy
     *                             session, or null when no session is active
     */
    public MiningDecision claimMiningContribution(
        Object worldIdentity,
        long tick,
        VRBodyPart bodyPart,
        BlockPos requestedTarget,
        boolean currentlyDestroying,
        BlockPos currentDestroyTarget)
    {
        return claimMiningContribution(
            worldIdentity, tick, bodyPart, requestedTarget, currentlyDestroying,
            currentDestroyTarget, false);
    }

    /**
     * Coordinates the complete RT/Y block-mining snapshot before Vanilla
     * handles its attack key later in this client tick.
     *
     * <p>The first accepted source owns the Vanilla destroy session until it
     * finishes. If only the other input remains held on the same block, that
     * input drives one continuation using the pinned owner. Native RT has
     * priority only when a new session is selected; it cannot take over an
     * active routed session and silently change the tool/body part.</p>
     */
    public ButtonMiningPlan coordinateButtonMiningIntents(
        Object worldIdentity,
        long tick,
        BlockPos nativeMainTarget,
        VRBodyPart routedBodyPart,
        BlockPos routedTarget,
        boolean currentlyDestroying,
        BlockPos currentDestroyTarget)
    {
        if (worldIdentity == null) {
            return ButtonMiningPlan.NONE;
        }
        advance(worldIdentity, tick);

        BlockPos nativeTarget = immutableOrNull(nativeMainTarget);
        BlockPos secondaryTarget = immutableOrNull(routedTarget);
        VRBodyPart secondaryOwner = trackedIndex(routedBodyPart) >= 0
            ? routedBodyPart
            : null;
        if (secondaryOwner == null) {
            secondaryTarget = null;
        }

        // These are input-source snapshots, not logical-hand slots. Keeping
        // them separate is important when reverseHands maps physical Y to the
        // logical main hand: routed Y must never masquerade as native RT.
        this.buttonMiningFrameObserved = true;
        this.buttonMiningTargets[0] = nativeTarget;
        this.buttonMiningTargets[1] = secondaryTarget;

        reconcileButtonMiningSession(currentlyDestroying, currentDestroyTarget);

        if (this.buttonMiningSessionTarget == null && currentlyDestroying &&
            currentDestroyTarget != null)
        {
            if (currentDestroyTarget.equals(nativeTarget)) {
                beginButtonMiningSession(
                    currentDestroyTarget, VRBodyPart.MAIN_HAND,
                    ButtonMiningInput.NATIVE_MAIN);
            } else if (secondaryOwner != null && currentDestroyTarget.equals(secondaryTarget)) {
                beginButtonMiningSession(
                    currentDestroyTarget, secondaryOwner,
                    ButtonMiningInput.ROUTED);
            }
        }

        if (this.buttonMiningSessionTarget != null) {
            boolean nativeMatches = this.buttonMiningSessionTarget.equals(nativeTarget);
            boolean routedMatches = this.buttonMiningSessionTarget.equals(secondaryTarget);
            if (!nativeMatches && !routedMatches) {
                MiningDecision routedDecision = secondaryTarget == null
                    ? MiningDecision.REJECT_UNSUPPORTED
                    : MiningDecision.REJECT_DIFFERENT_TARGET;
                return new ButtonMiningPlan(
                    false, false, routedDecision, this.buttonMiningSessionOwner,
                    ButtonMiningInput.NONE);
            }

            if (this.buttonMiningSessionSource == ButtonMiningInput.NATIVE_MAIN && nativeMatches) {
                reserveMiningSource(this.buttonMiningSessionTarget);
                return new ButtonMiningPlan(
                    true, false,
                    routedMatches
                        ? MiningDecision.REJECT_DUPLICATE
                        : secondaryTarget == null
                            ? MiningDecision.REJECT_UNSUPPORTED
                            : MiningDecision.REJECT_DIFFERENT_TARGET,
                    this.buttonMiningSessionOwner, ButtonMiningInput.NONE);
            }

            ButtonMiningInput continuationSource =
                this.buttonMiningSessionSource == ButtonMiningInput.ROUTED && routedMatches
                    ? ButtonMiningInput.ROUTED
                    : nativeMatches
                        ? ButtonMiningInput.NATIVE_MAIN
                        : ButtonMiningInput.ROUTED;
            reserveMiningSource(this.buttonMiningSessionTarget);
            return new ButtonMiningPlan(
                false, false, MiningDecision.CONTINUE,
                this.buttonMiningSessionOwner, continuationSource);
        }

        if (nativeTarget != null) {
            beginButtonMiningSession(
                nativeTarget, VRBodyPart.MAIN_HAND, ButtonMiningInput.NATIVE_MAIN);
            reserveMiningSource(nativeTarget);
            MiningDecision routedDecision = secondaryTarget == null
                ? MiningDecision.REJECT_UNSUPPORTED
                : nativeTarget.equals(secondaryTarget)
                    ? MiningDecision.REJECT_DUPLICATE
                    : MiningDecision.REJECT_DIFFERENT_TARGET;
            boolean synthesizePress = !currentlyDestroying ||
                currentDestroyTarget == null || !nativeTarget.equals(currentDestroyTarget);
            return new ButtonMiningPlan(
                true, synthesizePress, routedDecision,
                VRBodyPart.MAIN_HAND, ButtonMiningInput.NONE);
        }

        if (secondaryTarget == null || secondaryOwner == null) {
            return ButtonMiningPlan.NONE;
        }
        if (currentlyDestroying && (currentDestroyTarget == null ||
            !secondaryTarget.equals(currentDestroyTarget)))
        {
            return new ButtonMiningPlan(
                false, false, MiningDecision.REJECT_DIFFERENT_TARGET,
                null, ButtonMiningInput.NONE);
        }

        beginButtonMiningSession(
            secondaryTarget, secondaryOwner, ButtonMiningInput.ROUTED);
        reserveMiningSource(secondaryTarget);
        return new ButtonMiningPlan(
            false, false,
            currentlyDestroying ? MiningDecision.CONTINUE : MiningDecision.START,
            secondaryOwner, ButtonMiningInput.ROUTED);
    }

    /**
     * Returns the item/body-part owner pinned by this tick's coordinated
     * button-mining frame, or {@code null} for an unrelated/stale target.
     *
     * <p>{@code sameDestroyTarget} runs later in the same Minecraft tick.
     * Requiring the exact world identity, tick and target prevents a native
     * RT check from borrowing an owner left by another world or session.</p>
     */
    public VRBodyPart pinnedButtonMiningOwner(
        Object worldIdentity, long tick, BlockPos target)
    {
        if (worldIdentity == null || target == null ||
            this.worldIdentity != worldIdentity || this.tick != tick ||
            !this.buttonMiningFrameObserved ||
            this.buttonMiningSessionTarget == null ||
            !this.buttonMiningSessionTarget.equals(target))
        {
            return null;
        }
        return this.buttonMiningSessionOwner;
    }

    /**
     * Claims a contribution produced by a held attack button.
     *
     * <p>Button and physical-swing paths share the same global source claim,
     * so a physical collision later in this tick cannot become a second
     * contributor. Accepted button calls additionally identify the Vanilla
     * destroy session whose release is coordinated by
     * {@link #miningStopDecision(Object, long, boolean, BlockPos)}.</p>
     */
    public MiningDecision claimButtonMiningContribution(
        Object worldIdentity,
        long tick,
        VRBodyPart bodyPart,
        BlockPos requestedTarget,
        boolean currentlyDestroying,
        BlockPos currentDestroyTarget)
    {
        return claimMiningContribution(
            worldIdentity, tick, bodyPart, requestedTarget, currentlyDestroying,
            currentDestroyTarget, true);
    }

    /**
     * Compatibility entry point for callers that publish logical-hand targets
     * separately. New code should use {@link #coordinateButtonMiningIntents}.
     */
    public void observeButtonMiningTargets(
        Object worldIdentity,
        long tick,
        BlockPos mainHandTarget,
        BlockPos offHandTarget)
    {
        if (worldIdentity == null) {
            return;
        }
        advance(worldIdentity, tick);
        this.buttonMiningFrameObserved = true;
        this.buttonMiningTargets[0] = immutableOrNull(mainHandTarget);
        this.buttonMiningTargets[1] = immutableOrNull(offHandTarget);
    }

    /**
     * Marks the same-tick global source slot for an RT contribution that the
     * unmodified Vanilla path will perform later in this client tick.
     *
     * <p>This deliberately does not claim {@link #buttonMiningSessionTarget}:
     * the method neither owns nor changes Vanilla's destroy session. It only
     * prevents a later room-scale collision from charging MAIN_HAND twice.</p>
     */
    public void observeNativeMainButtonMiningIntent(
        Object worldIdentity, long tick, BlockPos mainHandTarget)
    {
        if (worldIdentity == null || mainHandTarget == null) {
            return;
        }
        advance(worldIdentity, tick);
        // The ordinary main-hand path remains entirely Vanilla. Reserve the
        // one global source slot so neither SwingTracker nor routed Y can
        // become an additional contributor later in this tick.
        reserveMiningSource(mainHandTarget);
    }

    /**
     * Decides whether Vanilla's single stop/ABORT call belongs to a coordinated
     * button session. Physical-swing-only sessions deliberately defer to the
     * legacy Vivecraft behavior.
     */
    public MiningStopDecision miningStopDecision(
        Object worldIdentity,
        long tick,
        boolean currentlyDestroying,
        BlockPos currentDestroyTarget)
    {
        if (worldIdentity == null) {
            return MiningStopDecision.DEFER_TO_LEGACY;
        }
        advance(worldIdentity, tick);
        if (this.buttonMiningSessionTarget == null) {
            return MiningStopDecision.DEFER_TO_LEGACY;
        }
        if (!currentlyDestroying || currentDestroyTarget == null ||
            !this.buttonMiningSessionTarget.equals(currentDestroyTarget))
        {
            clearButtonMiningSession();
            return MiningStopDecision.DEFER_TO_LEGACY;
        }
        if (!this.buttonMiningFrameObserved) {
            return MiningStopDecision.DEFER_TO_LEGACY;
        }
        for (BlockPos target : this.buttonMiningTargets) {
            if (this.buttonMiningSessionTarget.equals(target)) {
                return MiningStopDecision.KEEP;
            }
        }
        return MiningStopDecision.STOP;
    }

    /** Clears ownership after Vanilla actually stops or finishes this session. */
    public void finishButtonMiningSession(Object worldIdentity, BlockPos target) {
        if (this.worldIdentity != worldIdentity || this.buttonMiningSessionTarget == null) {
            return;
        }
        if (target == null || this.buttonMiningSessionTarget.equals(target)) {
            clearButtonMiningSession();
        }
    }

    private MiningDecision claimMiningContribution(
        Object worldIdentity,
        long tick,
        VRBodyPart bodyPart,
        BlockPos requestedTarget,
        boolean currentlyDestroying,
        BlockPos currentDestroyTarget,
        boolean buttonSource)
    {
        int index = trackedIndex(bodyPart);
        if (worldIdentity == null || requestedTarget == null || index < 0) {
            return MiningDecision.REJECT_UNSUPPORTED;
        }
        advance(worldIdentity, tick);

        if (this.buttonMiningSessionTarget != null &&
            (!currentlyDestroying || currentDestroyTarget == null ||
                !this.buttonMiningSessionTarget.equals(currentDestroyTarget)))
        {
            clearButtonMiningSession();
        }

        if (this.miningSourceClaimed) {
            return requestedTarget.equals(this.miningTargetThisTick)
                ? MiningDecision.REJECT_DUPLICATE
                : MiningDecision.REJECT_DIFFERENT_TARGET;
        }
        if (currentlyDestroying) {
            if (currentDestroyTarget == null || !requestedTarget.equals(currentDestroyTarget)) {
                return MiningDecision.REJECT_DIFFERENT_TARGET;
            }
        }
        if (this.miningTargetThisTick != null &&
            !requestedTarget.equals(this.miningTargetThisTick))
        {
            return MiningDecision.REJECT_DIFFERENT_TARGET;
        }

        reserveMiningSource(requestedTarget);
        if (buttonSource) {
            if (this.buttonMiningSessionTarget == null) {
                beginButtonMiningSession(
                    requestedTarget, bodyPart, ButtonMiningInput.ROUTED);
            }
        }
        return currentlyDestroying ? MiningDecision.CONTINUE : MiningDecision.START;
    }

    public void reset() {
        this.worldIdentity = null;
        this.tick = Long.MIN_VALUE;
        clearTickState();
        clearButtonMiningSession();
    }

    private void advance(Object worldIdentity, long tick) {
        if (this.worldIdentity != worldIdentity) {
            this.worldIdentity = worldIdentity;
            this.tick = tick;
            clearTickState();
            clearButtonMiningSession();
            return;
        }
        if (this.tick == tick) {
            return;
        }
        this.tick = tick;
        clearTickState();
    }

    private void clearTickState() {
        Arrays.fill(this.entityTargetCounts, 0);
        Arrays.fill(this.buttonMiningTargets, null);
        this.miningTargetThisTick = null;
        this.miningSourceClaimed = false;
        this.buttonMiningFrameObserved = false;
    }

    private void reconcileButtonMiningSession(
        boolean currentlyDestroying, BlockPos currentDestroyTarget)
    {
        if (this.buttonMiningSessionTarget != null &&
            (!currentlyDestroying || currentDestroyTarget == null ||
                !this.buttonMiningSessionTarget.equals(currentDestroyTarget)))
        {
            clearButtonMiningSession();
        }
    }

    private void beginButtonMiningSession(
        BlockPos target, VRBodyPart owner, ButtonMiningInput source)
    {
        this.buttonMiningSessionTarget = target.immutable();
        this.buttonMiningSessionOwner = owner;
        this.buttonMiningSessionSource = source;
    }

    private void clearButtonMiningSession() {
        this.buttonMiningSessionTarget = null;
        this.buttonMiningSessionOwner = null;
        this.buttonMiningSessionSource = ButtonMiningInput.NONE;
    }

    private void reserveMiningSource(BlockPos target) {
        this.miningSourceClaimed = true;
        this.miningTargetThisTick = target.immutable();
    }

    private static BlockPos immutableOrNull(BlockPos target) {
        return target == null ? null : target.immutable();
    }

    private static int trackedIndex(VRBodyPart bodyPart) {
        if (bodyPart == null) {
            return -1;
        }
        return switch (bodyPart) {
            case MAIN_HAND -> 0;
            case OFF_HAND -> 1;
            case RIGHT_FOOT -> 2;
            case LEFT_FOOT -> 3;
            default -> -1;
        };
    }

    public enum MiningDecision {
        START(true),
        CONTINUE(true),
        REJECT_DUPLICATE(false),
        REJECT_DIFFERENT_TARGET(false),
        REJECT_UNSUPPORTED(false);

        private final boolean accepted;

        MiningDecision(boolean accepted) {
            this.accepted = accepted;
        }

        public boolean accepted() {
            return this.accepted;
        }
    }

    public enum MiningStopDecision {
        DEFER_TO_LEGACY,
        KEEP,
        STOP
    }

    /** Input snapshot selected to drive an owner-pinned custom continuation. */
    public enum ButtonMiningInput {
        NONE,
        NATIVE_MAIN,
        ROUTED
    }

    /** Immutable result consumed by the router before Vanilla handles keyAttack. */
    public record ButtonMiningPlan(
        boolean routeNativeMain,
        boolean synthesizeNativePress,
        MiningDecision routedDecision,
        VRBodyPart sessionOwner,
        ButtonMiningInput customTargetSource)
    {
        public static final ButtonMiningPlan NONE = new ButtonMiningPlan(
            false, false, MiningDecision.REJECT_UNSUPPORTED,
            null, ButtonMiningInput.NONE);

        public boolean hasCustomMiningDriver() {
            return this.routedDecision.accepted() &&
                this.sessionOwner != null &&
                this.customTargetSource != ButtonMiningInput.NONE;
        }
    }
}
