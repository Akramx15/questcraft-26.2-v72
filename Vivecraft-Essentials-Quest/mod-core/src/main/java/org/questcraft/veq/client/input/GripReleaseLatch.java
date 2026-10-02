package org.questcraft.veq.client.input;

import org.vivecraft.client_vr.provider.ControllerType;

/** Blocks a consumed calibration Grip until the runtime proves it released. */
final class GripReleaseLatch {
    private final boolean[] suppressed = new boolean[ControllerType.values().length];

    void suppressBoth() {
        for (ControllerType controller : ControllerType.values()) {
            this.suppressed[controller.ordinal()] = true;
        }
    }

    void observe(ControllerType controller, Sample sample) {
        if (controller != null && sample == Sample.RELEASED) {
            this.suppressed[controller.ordinal()] = false;
        }
    }

    boolean isSuppressed(ControllerType controller) {
        return controller == null || this.suppressed[controller.ordinal()];
    }

    void clearForShutdown() {
        for (ControllerType controller : ControllerType.values()) {
            this.suppressed[controller.ordinal()] = false;
        }
    }

    enum Sample {
        DOWN,
        RELEASED,
        UNKNOWN
    }
}
