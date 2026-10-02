package org.questcraft.veq.client.wrist;

/** How the opposite controller manipulates the live wrist preview while Grip is held. */
public enum WristCalibrationMode {
    MOVE_ROTATE,
    SCALE;

    public WristCalibrationMode next() {
        return this == MOVE_ROTATE ? SCALE : MOVE_ROTATE;
    }
}
