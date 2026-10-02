package org.vivecraft.client_vr.gameplay.screenhandlers;

/** Selects the direct movement-vector path used by native container screens. */
public final class NativeContainerMovementInput {
    private NativeContainerMovementInput() {
    }

    public static boolean shouldDriveMoveVector(
        boolean movementActive,
        boolean analogMovement,
        boolean nativeContainerMovement,
        boolean compatibilityBlocksMovement
    ) {
        return movementActive && (analogMovement || nativeContainerMovement) && !compatibilityBlocksMovement;
    }
}
