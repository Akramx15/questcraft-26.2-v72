package org.questcraft.veq.client.input;

public final class RadialContinuationPolicySelfTest {
    private RadialContinuationPolicySelfTest() {
    }

    public static void main(String[] args) {
        require(keep(true, true, false, false, false, false, true), "world keeps Grip open");
        reject("pause", false, true, false, false, false, false, true);
        reject("death", false, true, false, false, false, false, true);
        reject("menu", false, true, false, false, false, false, true);
        reject("world change", false, true, false, false, false, false, true);
        reject("tracking loss", true, false, false, false, false, false, true);
        reject("wrist", true, true, true, false, false, false, true);
        reject("calibration", true, true, true, false, false, false, true);
        reject("ImmersiveMC", true, true, false, true, false, false, true);
        reject("climb", true, true, false, false, true, false, true);
        reject("notched bow", true, true, false, false, false, true, true);
        reject("disabled", true, true, false, false, false, false, false);
    }

    private static void reject(String reason, boolean... values) {
        require(!keep(values), reason + " cancels without selection");
    }

    private static boolean keep(boolean... values) {
        return RadialContinuationPolicy.keepOpen(
                values[0], values[1], values[2], values[3], values[4], values[5], values[6]);
    }

    private static void require(boolean condition, String message) {
        if (!condition) {
            throw new AssertionError(message);
        }
    }
}
