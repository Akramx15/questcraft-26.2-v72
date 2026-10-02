package org.questcraft.veq.client.config;

import org.joml.Matrix4fc;
import org.joml.Quaternionfc;
import org.joml.Vector3f;

/** Local controller axis used as the palm normal. Kept configurable for runtimes with different grip poses. */
public enum PalmAxis {
    POSITIVE_X(1.0F, 0.0F, 0.0F),
    NEGATIVE_X(-1.0F, 0.0F, 0.0F),
    POSITIVE_Y(0.0F, 1.0F, 0.0F),
    NEGATIVE_Y(0.0F, -1.0F, 0.0F),
    POSITIVE_Z(0.0F, 0.0F, 1.0F),
    NEGATIVE_Z(0.0F, 0.0F, -1.0F);

    private final float x;
    private final float y;
    private final float z;

    PalmAxis(float x, float y, float z) {
        this.x = x;
        this.y = y;
        this.z = z;
    }

    public float worldUpScore(Quaternionfc rotation, Vector3f scratch) {
        scratch.set(x, y, z);
        rotation.transform(scratch);
        return scratch.y;
    }

    public Vector3f transformDirection(Matrix4fc rotation, Vector3f destination) {
        destination.set(x, y, z);
        return rotation.transformDirection(destination);
    }
}
