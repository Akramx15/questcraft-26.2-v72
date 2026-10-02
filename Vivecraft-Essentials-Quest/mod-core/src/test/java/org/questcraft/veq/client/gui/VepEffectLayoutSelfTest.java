package org.questcraft.veq.client.gui;

/** Golden VEP potion-strip bounds at compact and wide canvas sizes. */
public final class VepEffectLayoutSelfTest {
    private VepEffectLayoutSelfTest() {
    }

    public static void main(String[] args) {
        require(VepEffectLayout.calculate(123, 57, 258, 504, 0) == null,
                "zero effects must not claim a strip");
        requireBounds(VepEffectLayout.calculate(123, 57, 258, 504, 1),
                383, 57, 120, 32, "one compact effect with visible duration");
        requireBounds(VepEffectLayout.calculate(123, 57, 258, 504, 6),
                383, 57, 120, 162, "six compact effects with visible durations");
        requireBounds(VepEffectLayout.calculate(80, 42, 258, 720, 2),
                340, 42, 120, 65, "wide labels");
        System.out.println("VepEffectLayoutSelfTest PASS");
    }

    private static void requireBounds(VepEffectLayout.Bounds actual,
                                      int x,
                                      int y,
                                      int width,
                                      int height,
                                      String message) {
        require(actual != null && actual.x() == x && actual.y() == y
                        && actual.width() == width && actual.height() == height,
                message + ": " + actual);
    }

    private static void require(boolean condition, String message) {
        if (!condition) {
            throw new AssertionError(message);
        }
    }
}
