package org.vivecraft.client_vr.provider.openxr;

import org.lwjgl.openxr.*;

import static org.lwjgl.system.MemoryUtil.NULL;

/**
 * Render-thread-owned OpenXR input structs reused for every action poll.
 *
 * <p>LWJGL stack allocation avoids native leaks, but it still creates Java
 * wrapper objects for every queried action. These persistent structs keep the
 * hot polling path allocation-free while preserving the same OpenXR calls.</p>
 */
final class OpenXRInputPollingBuffers implements AutoCloseable {

    private final XrActionStateGetInfo getInfo = XrActionStateGetInfo.calloc()
        .type(XR10.XR_TYPE_ACTION_STATE_GET_INFO)
        .next(NULL);
    private final XrActionStateBoolean booleanState = XrActionStateBoolean.calloc()
        .type(XR10.XR_TYPE_ACTION_STATE_BOOLEAN)
        .next(NULL);
    private final XrActionStateFloat floatState = XrActionStateFloat.calloc()
        .type(XR10.XR_TYPE_ACTION_STATE_FLOAT)
        .next(NULL);
    private final XrActionStateVector2f vector2State = XrActionStateVector2f.calloc()
        .type(XR10.XR_TYPE_ACTION_STATE_VECTOR2F)
        .next(NULL);
    private final XrVector2f vector2Value = this.vector2State.currentState();
    private final XrActionStatePose poseState = XrActionStatePose.calloc()
        .type(XR10.XR_TYPE_ACTION_STATE_POSE)
        .next(NULL);

    XrActionStateGetInfo prepare(XrAction action, long subactionPath) {
        return this.getInfo.action(action).subactionPath(subactionPath);
    }

    XrActionStateBoolean booleanState() {
        return this.booleanState;
    }

    XrActionStateFloat floatState() {
        return this.floatState;
    }

    XrActionStateVector2f vector2State() {
        return this.vector2State;
    }

    XrVector2f vector2Value() {
        return this.vector2Value;
    }

    XrActionStatePose poseState() {
        return this.poseState;
    }

    @Override
    public void close() {
        this.poseState.close();
        this.vector2State.close();
        this.floatState.close();
        this.booleanState.close();
        this.getInfo.close();
    }
}
