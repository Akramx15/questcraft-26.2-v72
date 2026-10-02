package org.vivecraft.client_vr.gameplay.screenhandlers;

import org.joml.Matrix4f;
import org.joml.Matrix4fc;
import org.joml.Vector3f;
import org.joml.Vector3fc;

/**
 * Fixed local-axis conversion for Visor-authored overlay poses.
 *
 * <p>Visor and Vivecraft both submit overlay quads with local +X to the right,
 * +Y to the top, +Z as the geometric normal, and the same UV winding. Their
 * renderer-to-renderer basis is therefore the identity. Keeping that fact in
 * one named conversion is intentional: surface adapters must not smuggle the
 * old HMD-dependent 180 degree face flip back into pose composition.</p>
 */
public final class OverlayCoordinateBasis {
    private OverlayCoordinateBasis() {
    }

    /** Applies the fixed Visor-local to Vivecraft-local basis to a room pose. */
    public static Matrix4f visorToVivecraft(Matrix4fc visorRoomRotation, Matrix4f destination) {
        return destination.set(visorRoomRotation);
    }

    /** Converts a direction without allocating a temporary matrix. */
    public static Vector3f visorDirectionToVivecraft(Vector3fc visorDirection, Vector3f destination) {
        return destination.set(visorDirection);
    }
}
