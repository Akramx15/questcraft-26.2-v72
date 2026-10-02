package org.questcraft.veq.client.input;

import net.minecraft.world.InteractionHand;
import org.vivecraft.client_vr.provider.ControllerType;

/** Pure semantic routes. Physical-to-logical conversion stays in the provider. */
final class PerHandWorldActionPolicy {
    private PerHandWorldActionPolicy() {
    }

    static Route route(Command command) {
        return switch (command) {
            case MAIN_ATTACK, MAIN_USE_BUTTON ->
                    new Route(ControllerType.RIGHT, InteractionHand.MAIN_HAND);
            case OFFHAND_TRIGGER_USE, OFFHAND_ATTACK ->
                    new Route(ControllerType.LEFT, InteractionHand.OFF_HAND);
        };
    }

    /** The provider already converted physical handedness exactly once. */
    static Route attackBreakThisHand(ControllerType logicalController) {
        if (logicalController == null) {
            return null;
        }
        return new Route(logicalController, QuestHandMapping.interactionHand(logicalController));
    }

    /** True offhand attacks have no safe Vanilla fallback for their handless packet. */
    static boolean allowAttackBreakThisHand(
            InteractionHand hand,
            boolean baseWorldAllowed,
            boolean offhandAttackRoutingSupported
    ) {
        return baseWorldAllowed &&
                (hand == InteractionHand.MAIN_HAND || offhandAttackRoutingSupported);
    }

    /**
     * Chooses the meaning of one fresh LT press without changing inventory or
     * manufacturing a Vanilla attack packet that cannot identify a hand.
     *
     * <p>Unsupported servers, non-melee items, and non-entity targets retain
     * the existing offhand-use behavior. Once the press is unambiguously an
     * offhand melee attempt, a failed safety/range/charge gate blocks that
     * press instead of accidentally interacting with the target.</p>
     */
    static OffhandTriggerDecision offhandTriggerDecision(
            boolean serverAllowsDualWielding,
            boolean meleeItem,
            boolean entityTarget,
            boolean itemEnabled,
            boolean entityAttackable,
            boolean withinWorldBorder,
            boolean withinAttackRange,
            boolean attackChargeAllowed
    ) {
        if (!serverAllowsDualWielding || !meleeItem || !entityTarget) {
            return OffhandTriggerDecision.USE;
        }
        return itemEnabled && entityAttackable && withinWorldBorder &&
                withinAttackRange && attackChargeAllowed
                ? OffhandTriggerDecision.ATTACK
                : OffhandTriggerDecision.BLOCK;
    }

    static boolean allowMainAttack(boolean baseWorldAllowed, boolean mainUseRouted) {
        return baseWorldAllowed && !mainUseRouted;
    }

    /** B's physical source and immutable logical target must both be world-owned. */
    static boolean allowBoundMainUse(
            boolean targetWorldAllowed,
            boolean sourceWorldAllowed,
            boolean inputEnabled
    ) {
        return targetWorldAllowed && sourceWorldAllowed && inputEnabled;
    }

    /** Mirrors Vanilla's range + world-border gate before useItemOn. */
    static boolean allowBlockUse(boolean withinInteractionRange, boolean withinWorldBorder) {
        return withinInteractionRange && withinWorldBorder;
    }

    static BlockUseDecision blockUseDecision(
            boolean blockTarget,
            boolean withinInteractionRange,
            boolean withinWorldBorder
    ) {
        if (!blockTarget) {
            return BlockUseDecision.USE_ITEM;
        }
        return allowBlockUse(withinInteractionRange, withinWorldBorder)
                ? BlockUseDecision.USE_BLOCK
                : BlockUseDecision.STOP;
    }

    static EntityUseDecision entityUseDecision(
            boolean withinWorldBorder,
            boolean withinInteractionRange
    ) {
        if (!withinWorldBorder) {
            return EntityUseDecision.STOP;
        }
        return withinInteractionRange
                ? EntityUseDecision.INTERACT
                : EntityUseDecision.USE_ITEM;
    }

    /**
     * Minecraft 1.20.5+ evaluates no-item block-menu interactions only for the
     * main hand. Keep the controller ray and Vivecraft body part owned by the
     * logical offhand, but select the protocol-compatible interaction hand for
     * a known block menu. Sneaking deliberately preserves offhand placement.
     */
    static InteractionHand interactionHandForBlockMenu(
            InteractionHand requestedHand,
            boolean secondaryUseActive,
            boolean menuTarget
    ) {
        return requestedHand == InteractionHand.OFF_HAND &&
                menuTarget && !secondaryUseActive
                ? InteractionHand.MAIN_HAND
                : requestedHand;
    }

    /** Entity interaction remains item-first and always uses the requested hand. */
    static InteractionHand interactionHandForEntity(InteractionHand requestedHand) {
        return requestedHand;
    }

    enum Command {
        MAIN_ATTACK,
        MAIN_USE_BUTTON,
        OFFHAND_TRIGGER_USE,
        OFFHAND_ATTACK
    }

    enum OffhandTriggerDecision {
        USE,
        ATTACK,
        BLOCK
    }

    enum BlockUseDecision {
        USE_BLOCK,
        USE_ITEM,
        STOP
    }

    enum EntityUseDecision {
        INTERACT,
        USE_ITEM,
        STOP
    }

    record Route(ControllerType controller, InteractionHand hand) {
    }
}
