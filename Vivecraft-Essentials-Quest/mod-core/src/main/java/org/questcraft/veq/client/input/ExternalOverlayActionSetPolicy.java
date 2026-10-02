package org.questcraft.veq.client.input;

/** Pure gate used by the OpenXR mixin to expose handed GUI clicks in-world. */
public final class ExternalOverlayActionSetPolicy {
    private ExternalOverlayActionSetPolicy() {
    }

    public static boolean keyboardSetActive(
            boolean keyboardOverlayShowing,
            boolean externalPointerOwnsInput
    ) {
        return keyboardOverlayShowing || externalPointerOwnsInput;
    }
}
