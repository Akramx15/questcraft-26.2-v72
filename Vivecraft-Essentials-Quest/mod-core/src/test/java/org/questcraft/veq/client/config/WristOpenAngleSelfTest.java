package org.questcraft.veq.client.config;

import java.nio.file.Files;
import java.nio.file.Path;

/** Host regression coverage for the user-facing palm cone conversion. */
public final class WristOpenAngleSelfTest {
    private static final float EPSILON = 0.001F;

    private WristOpenAngleSelfTest() {
    }

    public static void main(String[] args) throws Exception {
        Path directory = Files.createTempDirectory("veq-open-angle-");
        Path configFile = directory.resolve("wrist_ui.json");

        WristUiConfig config = WristUiConfig.forTest(configFile);
        requireClose(config.openAngleDegrees(), (float) Math.toDegrees(Math.acos(0.20F)),
                "default threshold must retain its original gesture cone");

        config.setOpenAngleDegrees(60.0F);
        requireClose(config.openThreshold(), 0.50F,
                "60 degree cone must map to a 0.5 dot-product threshold");
        requireClose(config.closeThreshold(), 0.40F,
                "editing the cone must retain the default 0.1 hysteresis gap");

        WristUiConfig reloaded = WristUiConfig.forTest(configFile);
        requireClose(reloaded.openAngleDegrees(), 60.0F,
                "open angle must survive an atomic save and reload");
        require(reloaded.closeThreshold() < reloaded.openThreshold(),
                "close threshold must remain below the open threshold");

        reloaded.setOpenAngleDegrees(180.0F);
        requireClose(reloaded.openAngleDegrees(), WristUiConfig.MAX_OPEN_ANGLE_DEGREES,
                "oversized cone must clamp to the supported maximum");
        require(reloaded.closeThreshold() < reloaded.openThreshold(),
                "maximum cone must still keep nonzero hysteresis");

        reloaded.setOpenAngleDegrees(Float.NaN);
        requireClose(reloaded.openAngleDegrees(), WristUiConfig.MIN_OPEN_ANGLE_DEGREES,
                "non-finite input must fall back to the safe minimum");

        System.out.println("WristOpenAngleSelfTest PASS");
    }

    private static void requireClose(float actual, float expected, String message) {
        if (Math.abs(actual - expected) > EPSILON) {
            throw new AssertionError(message + ": expected=" + expected + ", actual=" + actual);
        }
    }

    private static void require(boolean condition, String message) {
        if (!condition) {
            throw new AssertionError(message);
        }
    }
}
