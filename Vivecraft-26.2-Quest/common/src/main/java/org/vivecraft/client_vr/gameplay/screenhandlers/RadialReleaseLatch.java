package org.vivecraft.client_vr.gameplay.screenhandlers;

import org.vivecraft.client_vr.provider.ControllerType;

import java.util.Objects;

/**
 * One-shot release gate for a handed radial hold.
 *
 * <p>A selection is legal only after this exact controller supplied a valid
 * DOWN sample and later supplies a valid RELEASED sample. Losing the action
 * set, binding, or origin is UNKNOWN and cancels the session instead of
 * synthesizing a release.</p>
 */
final class RadialReleaseLatch {
    private final ControllerType owner;
    private boolean armed;

    RadialReleaseLatch(ControllerType owner) {
        this.owner = Objects.requireNonNull(owner, "owner");
    }

    Decision update(ControllerType controller, Sample sample) {
        if (controller != this.owner || sample == null || sample == Sample.UNKNOWN) {
            return Decision.CANCEL;
        }
        if (!this.armed) {
            if (sample != Sample.DOWN) {
                return Decision.CANCEL;
            }
            this.armed = true;
            return Decision.KEEP_OPEN;
        }
        return sample == Sample.DOWN ? Decision.KEEP_OPEN : Decision.SELECT_AND_CLOSE;
    }

    static Sample sample(boolean handed,
                         boolean enabled,
                         boolean active,
                         boolean originPresent,
                         boolean originMatchesOwner,
                         boolean pressed) {
        if (!handed || !enabled || !active || !originPresent || !originMatchesOwner) {
            return Sample.UNKNOWN;
        }
        return pressed ? Sample.DOWN : Sample.RELEASED;
    }

    enum Sample {
        DOWN,
        RELEASED,
        UNKNOWN
    }

    enum Decision {
        KEEP_OPEN,
        SELECT_AND_CLOSE,
        CANCEL
    }
}
