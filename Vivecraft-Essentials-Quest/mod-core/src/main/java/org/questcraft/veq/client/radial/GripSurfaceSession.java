package org.questcraft.veq.client.radial;

import org.vivecraft.client_vr.provider.ControllerType;

/** Independent no-queue visibility state owned by exactly one Grip surface. */
final class GripSurfaceSession {
    private final ControllerType owner;
    private boolean showing;

    GripSurfaceSession(ControllerType owner) {
        if (owner == null) {
            throw new IllegalArgumentException("Grip surface owner cannot be null");
        }
        this.owner = owner;
    }

    boolean open(ControllerType requester, boolean gripDown) {
        if (requester != this.owner || !gripDown) {
            return false;
        }
        this.showing = true;
        return true;
    }

    void close() {
        this.showing = false;
    }

    boolean isShowing() {
        return this.showing;
    }

    boolean owns(ControllerType controller) {
        return this.showing && controller == this.owner;
    }
}
