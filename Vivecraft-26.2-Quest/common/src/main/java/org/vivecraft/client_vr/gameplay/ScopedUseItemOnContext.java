package org.vivecraft.client_vr.gameplay;

import net.minecraft.core.BlockPos;
import net.minecraft.core.Direction;
import net.minecraft.world.phys.BlockHitResult;
import net.minecraft.world.phys.Vec3;
import org.joml.Vector3f;
import org.joml.Vector3fc;
import org.vivecraft.client_vr.provider.ControllerType;

import java.util.Objects;

/**
 * Thread-confined context for a protocol-only {@code useItemOn} hand translation.
 *
 * <p>Quest maps L2 to logical LEFT/OFF_HAND. Some menu blocks require a
 * MAIN_HAND protocol interaction, but that translation must not also rebind
 * the controller pose used for the server-facing look override. The immutable
 * ray and hit captured here preserve the logical LEFT interaction across the
 * translated call without consulting the mutable global crosshair.</p>
 */
public final class ScopedUseItemOnContext {
    private static final double MIN_DIRECTION_LENGTH_SQUARED = 1.0E-12D;
    private static final ThreadLocal<Snapshot> CURRENT = new ThreadLocal<>();

    private ScopedUseItemOnContext() {
    }

    public static Scope openTranslatedLeft(
        ControllerType logicalController,
        Vec3 rayOrigin,
        Vec3 rayDirection,
        BlockHitResult hitResult)
    {
        if (logicalController != ControllerType.LEFT) {
            throw new IllegalArgumentException("translated menu use must retain logical LEFT");
        }
        Objects.requireNonNull(hitResult, "hitResult");
        Snapshot previous = CURRENT.get();
        Snapshot snapshot = new Snapshot(
            logicalController,
            rayOrigin,
            rayDirection,
            hitResult.getLocation(),
            hitResult.getBlockPos(),
            hitResult.getDirection());
        CURRENT.set(snapshot);
        return new Scope(previous, snapshot);
    }

    public static Snapshot current() {
        return CURRENT.get();
    }

    public record Snapshot(
        ControllerType logicalController,
        Vec3 rayOrigin,
        Vec3 rayDirection,
        Vec3 hitLocation,
        BlockPos blockPosition,
        Direction hitFace)
    {
        public Snapshot {
            Objects.requireNonNull(logicalController, "logicalController");
            Objects.requireNonNull(rayOrigin, "rayOrigin");
            Objects.requireNonNull(rayDirection, "rayDirection");
            Objects.requireNonNull(hitLocation, "hitLocation");
            Objects.requireNonNull(blockPosition, "blockPosition");
            Objects.requireNonNull(hitFace, "hitFace");
            if (rayDirection.lengthSqr() <= MIN_DIRECTION_LENGTH_SQUARED) {
                throw new IllegalArgumentException("rayDirection must be non-zero");
            }
            rayDirection = rayDirection.normalize();
            blockPosition = blockPosition.immutable();
        }

        /** Uses the exact captured hit, falling back to the captured ray at zero distance. */
        public Vector3fc lookDirection(Vec3 eyePosition) {
            Objects.requireNonNull(eyePosition, "eyePosition");
            Vec3 eyeToHit = this.hitLocation.subtract(eyePosition);
            Vec3 direction = eyeToHit.lengthSqr() > MIN_DIRECTION_LENGTH_SQUARED ?
                eyeToHit.normalize() : this.rayDirection;
            return new Vector3f((float) direction.x, (float) direction.y, (float) direction.z);
        }
    }

    public static final class Scope implements AutoCloseable {
        private final Snapshot previous;
        private final Snapshot installed;
        private boolean closed;

        private Scope(Snapshot previous, Snapshot installed) {
            this.previous = previous;
            this.installed = installed;
        }

        @Override
        public void close() {
            if (this.closed) {
                return;
            }
            this.closed = true;
            if (CURRENT.get() != this.installed) {
                throw new IllegalStateException("translated useItemOn scopes closed out of order");
            }
            if (this.previous == null) {
                CURRENT.remove();
            } else {
                CURRENT.set(this.previous);
            }
        }
    }
}
