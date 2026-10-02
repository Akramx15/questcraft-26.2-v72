package org.questcraft.veq.client.input;

import net.minecraft.world.InteractionHand;

/**
 * Per-hand attack-button snapshot consumed only by the optional ImmersiveMC
 * compatibility mixins.
 *
 * <p>ImmersiveMC 1.6.0-alpha4.1 reads Minecraft's single global attack key
 * while deciding whether a VR hitbox is a trigger interaction or a drag. VEQ
 * routes Quest attack inputs through handed actions instead, and deliberately
 * releases the global key while ImmersiveMC owns a hand so an attack cannot
 * leak into the world behind the immersive. This snapshot preserves the
 * handed button state without reopening that world-action path.</p>
 *
 * <p>An unknown sample always falls back to ImmersiveMC's original key value.
 * That keeps the optional bridge fail-open when an action, controller origin,
 * tracking pose, or compatible ImmersiveMC injection point is unavailable.</p>
 */
public final class ImmersiveAttackState {
    private static final byte UNKNOWN = 0;
    private static final byte RELEASED = 1;
    private static final byte DOWN = 2;

    private static byte mainHand = UNKNOWN;
    private static byte offHand = UNKNOWN;

    private ImmersiveAttackState() {
    }

    /** Starts a new input snapshot and prevents a stale press crossing ticks. */
    static void beginFrame() {
        mainHand = UNKNOWN;
        offHand = UNKNOWN;
    }

    /**
     * Adds one handed action sample after the immutable ownership snapshot has
     * assigned that hand. Only ImmersiveMC may receive the handed Quest input;
     * every other concrete owner explicitly suppresses the global Vanilla key
     * so a Wrist, bow, climb, Grip, or world press cannot leak into an
     * immersive interaction.
     */
    static void observe(
            InteractionHand hand,
            LeftUseCapture.Sample sample,
            HandActionPriority.Owner owner
    ) {
        if (hand == null || owner == null) {
            return;
        }
        if (owner != HandActionPriority.Owner.IMMERSIVE) {
            // WORLD has no immersive owner, so preserve upstream's original
            // key read. Concrete higher-priority owners must instead force a
            // release: UNKNOWN would fall back to the shared global key and
            // could leak the opposite controller into ImmersiveMC.
            if (owner != HandActionPriority.Owner.WORLD) {
                suppress(hand);
            }
            return;
        }
        if (sample == null || sample == LeftUseCapture.Sample.UNKNOWN) {
            return;
        }
        byte observed = sample == LeftUseCapture.Sample.DOWN ? DOWN : RELEASED;
        if (hand == InteractionHand.MAIN_HAND) {
            mainHand = merge(mainHand, observed);
        } else {
            offHand = merge(offHand, observed);
        }
    }

    /** Clears one lost hand while allowing the other tracked hand to continue. */
    static void clear(InteractionHand hand) {
        if (hand == InteractionHand.MAIN_HAND) {
            mainHand = UNKNOWN;
        } else if (hand == InteractionHand.OFF_HAND) {
            offHand = UNKNOWN;
        }
    }

    /** Forces one known-unavailable hand up without consulting the global key. */
    static void suppress(InteractionHand hand) {
        set(hand, RELEASED);
    }

    /** Clears all state on lifecycle replacement, world loss, or VR shutdown. */
    public static void clear() {
        mainHand = UNKNOWN;
        offHand = UNKNOWN;
    }

    /**
     * Resolves an ImmersiveMC key read for the hand it is currently processing.
     * Unknown/null hands preserve the original mod behavior.
     */
    public static boolean resolve(InteractionHand hand, boolean originalKeyDown) {
        byte state = hand == InteractionHand.MAIN_HAND
                ? mainHand
                : hand == InteractionHand.OFF_HAND ? offHand : UNKNOWN;
        return switch (state) {
            case DOWN -> true;
            case RELEASED -> false;
            default -> originalKeyDown;
        };
    }

    private static byte merge(byte current, byte observed) {
        return current == DOWN || observed == DOWN ? DOWN : observed;
    }

    private static void set(InteractionHand hand, byte state) {
        if (hand == InteractionHand.MAIN_HAND) {
            mainHand = state;
        } else if (hand == InteractionHand.OFF_HAND) {
            offHand = state;
        }
    }
}
