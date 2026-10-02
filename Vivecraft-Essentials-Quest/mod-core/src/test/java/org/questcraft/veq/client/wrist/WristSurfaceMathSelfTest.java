package org.questcraft.veq.client.wrist;

import org.joml.Matrix4f;
import org.joml.Vector2f;
import org.joml.Vector3f;

public final class WristSurfaceMathSelfTest {
    private WristSurfaceMathSelfTest() {
    }

    public static void main(String[] args) {
        Vector2f uv = new Vector2f();
        Vector3f normal = new Vector3f();
        Vector3f right = new Vector3f();
        Vector3f up = new Vector3f();
        Vector3f topLeft = new Vector3f();
        Vector3f delta = new Vector3f();
        Vector3f intersection = new Vector3f();
        Matrix4f identity = new Matrix4f();

        boolean hit = WristSurfaceMath.rayToUv(
                new Vector3f(0.0F, 0.0F, 1.0F),
                new Vector3f(0.0F, 0.0F, -1.0F),
                new Vector3f(),
                identity,
                0.5F,
                0.5625F,
                uv,
                normal,
                right,
                up,
                topLeft,
                delta,
                intersection
        );
        require(hit, "center ray intersects");
        require(Math.abs(uv.x - 0.5F) < 1.0E-5F, "center u");
        require(Math.abs(uv.y - 0.5F) < 1.0E-5F, "center v");
        require(WristSurfaceMath.isWithin(uv, 0.25F, 0.25F, 0.75F, 0.75F),
                "center lies inside embedded panel");

        boolean rightEdge = WristSurfaceMath.rayToUv(
                new Vector3f(0.30F, 0.0F, 1.0F),
                new Vector3f(0.0F, 0.0F, -1.0F),
                new Vector3f(),
                identity,
                0.5F,
                0.5625F,
                uv,
                normal,
                right,
                up,
                topLeft,
                delta,
                intersection
        );
        require(rightEdge, "off-center front ray intersects");
        require(uv.x > 0.5F, "rendered local +X must increase U");

        boolean leftEdge = WristSurfaceMath.rayToUv(
                new Vector3f(-0.30F, 0.0F, 1.0F),
                new Vector3f(0.0F, 0.0F, -1.0F),
                new Vector3f(),
                identity,
                0.5F,
                0.5625F,
                uv,
                normal,
                right,
                up,
                topLeft,
                delta,
                intersection
        );
        require(leftEdge, "opposite off-center front ray intersects");
        require(uv.x < 0.5F, "rendered local -X must decrease U");

        boolean outside = WristSurfaceMath.rayToUv(
                new Vector3f(0.90F, 0.0F, 1.0F),
                new Vector3f(0.0F, 0.0F, -1.0F),
                new Vector3f(),
                identity,
                0.5F,
                0.5625F,
                uv,
                normal,
                right,
                up,
                topLeft,
                delta,
                intersection
        );
        require(outside, "front plane intersection survives outside the quad");
        require(uv.x > 1.0F, "outside drag retains unclamped real plane U");

        boolean behind = WristSurfaceMath.rayToUv(
                new Vector3f(0.0F, 0.0F, 1.0F),
                new Vector3f(0.0F, 0.0F, 1.0F),
                new Vector3f(),
                identity,
                0.5F,
                0.5625F,
                uv,
                normal,
                right,
                up,
                topLeft,
                delta,
                intersection
        );
        require(!behind, "ray pointing away cannot acquire the panel");

        boolean backFace = WristSurfaceMath.rayToUv(
                new Vector3f(0.0F, 0.0F, -1.0F),
                new Vector3f(0.0F, 0.0F, 1.0F),
                new Vector3f(),
                identity,
                0.5F,
                0.5625F,
                uv,
                normal,
                right,
                up,
                topLeft,
                delta,
                intersection
        );
        require(!backFace, "back-face ray must not acquire the panel");
        System.out.println("WristSurfaceMathSelfTest PASS");
    }

    private static void require(boolean condition, String message) {
        if (!condition) {
            throw new AssertionError(message);
        }
    }
}
