package org.vivecraft.client_vr.provider.openxr;

import org.vivecraft.client_vr.provider.ControllerType;

/**
 * Converts between Vivecraft's logical controller indices and OpenXR's
 * physical hand paths. OpenXR action spaces stay physical for their entire
 * lifetime; reverse-hands is applied only when data crosses this boundary.
 */
final class OpenXRHandedness {
    private static final int HAND_COUNT = 2;

    private OpenXRHandedness() {
    }

    static int physicalIndex(int logicalIndex, boolean reverseHands) {
        if (logicalIndex < 0 || logicalIndex >= HAND_COUNT) {
            throw new IllegalArgumentException("Invalid logical controller index: " + logicalIndex);
        }
        return reverseHands ? 1 - logicalIndex : logicalIndex;
    }

    static ControllerType logicalController(ControllerType physicalController, boolean reverseHands) {
        if (physicalController == null || !reverseHands) {
            return physicalController;
        }
        return physicalController == ControllerType.RIGHT ? ControllerType.LEFT : ControllerType.RIGHT;
    }
}
