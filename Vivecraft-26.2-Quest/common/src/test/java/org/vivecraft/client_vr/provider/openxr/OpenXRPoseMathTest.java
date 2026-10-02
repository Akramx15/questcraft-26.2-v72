package org.vivecraft.client_vr.provider.openxr;

import org.joml.Matrix4f;
import org.junit.jupiter.api.Assertions;
import org.junit.jupiter.api.Test;

class OpenXRPoseMathTest {
    @Test
    void aimTimesRelativeTransformReconstructsFullGripPose() {
        Matrix4f aim = new Matrix4f()
            .rotationXYZ(0.2F, 0.4F, -0.1F)
            .setTranslation(1.0F, 2.0F, 3.0F);
        Matrix4f grip = new Matrix4f()
            .rotationXYZ(-0.3F, 0.15F, 0.5F)
            .setTranslation(-4.0F, 5.0F, -6.0F);
        Matrix4f inverseScratch = new Matrix4f();
        Matrix4f relative = new Matrix4f();

        OpenXRPoseMath.aimToGrip(aim, grip, inverseScratch, relative);

        Matrix4f reconstructed = new Matrix4f(aim).mul(relative);
        Matrix4f expected = new Matrix4f(grip);
        assertMatrixEquals(expected, reconstructed, 1.0E-5F);
        Assertions.assertNotEquals(0.0F,
            Math.abs(relative.m30()) + Math.abs(relative.m31()) + Math.abs(relative.m32()), 1.0E-6F);
    }

    @Test
    void helperReusesCallerOwnedStorage() {
        Matrix4f aim = new Matrix4f().rotationY(0.25F);
        Matrix4f grip = new Matrix4f().rotationX(-0.5F);
        Matrix4f inverseScratch = new Matrix4f();
        Matrix4f destination = new Matrix4f();

        OpenXRPoseMath.aimToGrip(aim, grip, inverseScratch, destination);
        Matrix4f first = new Matrix4f(destination);
        OpenXRPoseMath.aimToGrip(aim, grip, inverseScratch, destination);

        assertMatrixEquals(first, destination, 0.0F);
    }

    private static void assertMatrixEquals(Matrix4f expected, Matrix4f actual, float epsilon) {
        for (int column = 0; column < 4; column++) {
            for (int row = 0; row < 4; row++) {
                Assertions.assertEquals(expected.get(column, row), actual.get(column, row), epsilon,
                    "matrix component [" + column + "," + row + "]");
            }
        }
    }
}
