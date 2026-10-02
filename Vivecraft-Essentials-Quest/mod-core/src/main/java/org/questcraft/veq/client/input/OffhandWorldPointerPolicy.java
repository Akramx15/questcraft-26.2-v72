package org.questcraft.veq.client.input;

/** Pure fail-closed visibility policy for the logical-left world pointer. */
final class OffhandWorldPointerPolicy {
    private OffhandWorldPointerPolicy() {
    }

    static boolean shouldRender(
            boolean runtimeReady,
            boolean handWorldAllowed,
            boolean trackingValid,
            boolean pointerSettingAllows,
            boolean firstPersonPass,
            boolean viewOnly,
            boolean keyboardShowing,
            boolean roomGuiShowing,
            boolean paused,
            boolean vanillaOverlayShowing,
            boolean wristShowing,
            boolean gripShowing,
            boolean teleportAiming,
            boolean worldScaleValid
    ) {
        return runtimeReady && handWorldAllowed && trackingValid && pointerSettingAllows &&
                firstPersonPass && !viewOnly && !keyboardShowing && !roomGuiShowing &&
                !paused && !vanillaOverlayShowing && !wristShowing && !gripShowing &&
                !teleportAiming && worldScaleValid;
    }
}
