package org.questcraft.veq.client.input;

import net.minecraft.world.InteractionHand;
import org.vivecraft.client_vr.provider.ExternalHandUseState;

/** Mutable router state with one observable, fail-closed lifecycle reset. */
final class PerHandTransientState {
    private final IndependentAttackLatch mainAttackLatch = new IndependentAttackLatch();
    private final OffhandAttackLatch offhandAttackLatch = new OffhandAttackLatch();
    private final AttackBreakThisHandLatch attackBreakThisHandLatch =
            new AttackBreakThisHandLatch();
    private final IndependentHandUseLatch useLatch = new IndependentHandUseLatch();
    private final IndependentUseCooldown mainUseCooldown = new IndependentUseCooldown();
    private final IndependentUseCooldown offhandUseCooldown = new IndependentUseCooldown();
    private final MenuBlockAttemptLatch menuBlockAttemptLatch = new MenuBlockAttemptLatch();
    private boolean mainAttackHeld;
    private InteractionHand externalHeldHand;

    void tickCooldowns() {
        this.mainUseCooldown.tick();
        this.offhandUseCooldown.tick();
    }

    IndependentHandUseLatch.Outcome updateUses(
            LeftUseCapture.Sample mainSample,
            boolean mainAllowed,
            LeftUseCapture.Sample offhandSample,
            boolean offhandAllowed
    ) {
        return this.useLatch.update(mainSample, mainAllowed, offhandSample, offhandAllowed);
    }

    boolean updateMainAttacks(
            LeftUseCapture.Sample triggerSample,
            boolean triggerAllowed,
            LeftUseCapture.Sample buttonSample,
            boolean buttonAllowed
    ) {
        return this.mainAttackLatch.update(
                triggerSample, triggerAllowed, buttonSample, buttonAllowed);
    }

    boolean updateOffhandAttack(LeftUseCapture.Sample sample, boolean attackAllowed) {
        return this.offhandAttackLatch.update(sample, attackAllowed);
    }

    AttackBreakThisHandLatch.Outcome updateAttackBreakThisHand(
            org.vivecraft.client_vr.provider.ControllerType controller,
            LeftUseCapture.Sample sample,
            boolean worldAllowed
    ) {
        return this.attackBreakThisHandLatch.update(controller, sample, worldAllowed);
    }

    boolean cooldownReady(InteractionHand hand) {
        return cooldown(hand).ready();
    }

    void armCooldown(InteractionHand hand, int delayTicks) {
        cooldown(hand).arm(delayTicks);
    }

    void observeMenuBlockAttempt(LeftUseCapture.Sample sample, Object screenIdentity) {
        this.menuBlockAttemptLatch.observe(sample, screenIdentity);
    }

    void observeOffhandOwnership(boolean worldAllowed, LeftUseCapture.Sample sample) {
        this.menuBlockAttemptLatch.observeOwnership(worldAllowed, sample);
    }

    boolean claimMenuBlockAttempt() {
        return this.menuBlockAttemptLatch.claim();
    }

    boolean beginMainAttack() {
        if (this.mainAttackHeld) {
            return false;
        }
        this.mainAttackHeld = true;
        return true;
    }

    boolean releaseMainAttack() {
        if (!this.mainAttackHeld) {
            return false;
        }
        this.mainAttackHeld = false;
        return true;
    }

    InteractionHand externalHeldHand() {
        return this.externalHeldHand;
    }

    void setExternalHeldHand(InteractionHand hand) {
        this.externalHeldHand = hand;
    }

    void clearExternalHeldHand() {
        this.externalHeldHand = null;
    }

    /** Returns whether the caller must release the simulated attack key. */
    boolean resetForLifecycle() {
        this.mainAttackLatch.suppressUntilRelease();
        this.offhandAttackLatch.suppressUntilRelease();
        this.attackBreakThisHandLatch.suppressUntilRelease();
        this.useLatch.suppressUntilRelease();
        this.mainUseCooldown.clear();
        this.offhandUseCooldown.clear();
        this.menuBlockAttemptLatch.suppressUntilRelease();
        this.externalHeldHand = null;
        ExternalHandUseState.setHeld(false);
        return releaseMainAttack();
    }

    private IndependentUseCooldown cooldown(InteractionHand hand) {
        return hand == InteractionHand.MAIN_HAND
                ? this.mainUseCooldown
                : this.offhandUseCooldown;
    }
}
