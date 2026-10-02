package org.vivecraft.client_vr.gameplay.screenhandlers;

import org.joml.Matrix4f;
import org.joml.Vector3f;
import org.junit.jupiter.api.Assertions;
import org.junit.jupiter.api.Test;

class OverlayCoordinateBasisTest {
    private static final float EPSILON = 1.0E-5F;

    @Test
    void fixedBasisPreservesTheSharedOverlayAxes() {
        Matrix4f converted = OverlayCoordinateBasis.visorToVivecraft(new Matrix4f(), new Matrix4f());

        assertVector(new Vector3f(1, 0, 0), converted.transformDirection(1, 0, 0, new Vector3f()));
        assertVector(new Vector3f(0, 1, 0), converted.transformDirection(0, 1, 0, new Vector3f()));
        assertVector(new Vector3f(0, 0, 1), converted.transformDirection(0, 0, 1, new Vector3f()));
    }

    @Test
    void conversionIsIndependentOfHeadPoseAndDoesNotAutoFlip() {
        Matrix4f visorPose = new Matrix4f().rotateY(0.63F).rotateZ(-0.2F);
        Matrix4f first = OverlayCoordinateBasis.visorToVivecraft(visorPose, new Matrix4f());
        Matrix4f second = OverlayCoordinateBasis.visorToVivecraft(visorPose, new Matrix4f());
        Assertions.assertTrue(first.equals(second, EPSILON));
    }

    @Test
    void allocationFreeDirectionHelperUsesTheSameBasis() {
        Vector3f destination = new Vector3f();
        Assertions.assertSame(destination,
            OverlayCoordinateBasis.visorDirectionToVivecraft(new Vector3f(2, 3, -4), destination));
        assertVector(new Vector3f(2, 3, -4), destination);
    }

    private static void assertVector(Vector3f expected, Vector3f actual) {
        Assertions.assertEquals(expected.x, actual.x, EPSILON);
        Assertions.assertEquals(expected.y, actual.y, EPSILON);
        Assertions.assertEquals(expected.z, actual.z, EPSILON);
    }
}
