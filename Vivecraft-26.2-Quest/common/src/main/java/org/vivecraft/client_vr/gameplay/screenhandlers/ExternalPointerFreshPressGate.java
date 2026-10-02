package org.vivecraft.client_vr.gameplay.screenhandlers;

import org.vivecraft.client_vr.provider.ControllerType;

import javax.annotation.Nullable;
import java.util.Arrays;
import java.util.Objects;

/**
 * Admits a pointer button only after its current per-hand owner has observed
 * two active neutral samples. Owner identity is intentional: changing surfaces
 * while a physical button is held must not replay the old press on the new one.
 * The raw OpenXR origin is part of that identity so reverse-hands/profile
 * changes cannot move a held button into an already armed logical-hand slot.
 */
final class ExternalPointerFreshPressGate {
    private final Object[] owners = new Object[ControllerType.values().length];
    private final long[] origins = new long[ControllerType.values().length];
    private final boolean[] waitingForRelease = new boolean[ControllerType.values().length];
    private final boolean[] sampledNeutralOnce = new boolean[ControllerType.values().length];
    private final boolean[] previousDown = new boolean[ControllerType.values().length];

    Routing update(ControllerType controller, @Nullable Object owner, boolean actionActive,
                   long origin, boolean rawDown)
    {
        Objects.requireNonNull(controller, "controller");
        int index = controller.ordinal();

        if (owner == null || !actionActive || origin == 0L) {
            this.clear(index);
            return Routing.IDLE;
        }

        if (this.owners[index] != owner || this.origins[index] != origin) {
            this.owners[index] = owner;
            this.origins[index] = origin;
            this.waitingForRelease[index] = true;
            this.sampledNeutralOnce[index] = !rawDown;
            this.previousDown[index] = rawDown;
            return Routing.IDLE;
        }

        if (this.waitingForRelease[index]) {
            if (rawDown) {
                this.sampledNeutralOnce[index] = false;
            } else if (this.sampledNeutralOnce[index]) {
                this.waitingForRelease[index] = false;
                this.sampledNeutralOnce[index] = false;
            } else {
                this.sampledNeutralOnce[index] = true;
            }
            this.previousDown[index] = rawDown;
            return Routing.IDLE;
        }

        boolean pressedEdge = rawDown && !this.previousDown[index];
        this.previousDown[index] = rawDown;
        return new Routing(pressedEdge, rawDown);
    }

    void reset() {
        Arrays.fill(this.owners, null);
        Arrays.fill(this.origins, 0L);
        Arrays.fill(this.waitingForRelease, false);
        Arrays.fill(this.sampledNeutralOnce, false);
        Arrays.fill(this.previousDown, false);
    }

    private void clear(int index) {
        this.owners[index] = null;
        this.origins[index] = 0L;
        this.waitingForRelease[index] = false;
        this.sampledNeutralOnce[index] = false;
        this.previousDown[index] = false;
    }

    record Routing(boolean pressedEdge, boolean buttonDown) {
        private static final Routing IDLE = new Routing(false, false);
    }
}
