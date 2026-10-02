package org.vivecraft.client_vr.provider.openxr;

import org.lwjgl.openxr.*;
import org.lwjgl.system.MemoryStack;
import org.vivecraft.client_vr.provider.ControllerType;
import org.vivecraft.client_vr.provider.HapticScheduler;

import java.util.concurrent.TimeUnit;

import static java.sql.Types.NULL;

public class OpenXRHapticScheduler extends HapticScheduler {

    private void triggerHapticPulse(
        ControllerType controller, float durationSeconds, float frequency, float amplitude)
    {
        try (MemoryStack stack = MemoryStack.stackPush()){
            // MCVR has already converted Vivecraft's logical controller to the
            // physical controller when reverse-hands is enabled. Do not swap a
            // second time here.
            int i = controller == ControllerType.RIGHT ? 0 : 1;
            XrHapticActionInfo info = XrHapticActionInfo.calloc(stack);
            info.type(XR10.XR_TYPE_HAPTIC_ACTION_INFO);
            info.next(NULL);
            info.action(MCOpenXR.get().getHapticAction(i));

            XrHapticVibration vibration = XrHapticVibration.calloc(stack);
            vibration.type(XR10.XR_TYPE_HAPTIC_VIBRATION);
            vibration.next(NULL);
            vibration.duration((long) (durationSeconds * 1_000_000_000));
            vibration.frequency(frequency);
            vibration.amplitude(amplitude);

            int error = XR10.xrApplyHapticFeedback(MCOpenXR.get().session, info, XrHapticBaseHeader.create(vibration));
            MCOpenXR.get().logError(error, "xrApplyHapticFeedback", "");
        }
    }

    @Override
    public void queueHapticPulse(ControllerType controller, float durationSeconds, float frequency, float amplitude, float delaySeconds) {
        this.scheduleHapticPulse(() ->
        {
            this.triggerHapticPulse(controller, durationSeconds, frequency, amplitude);
        }, (long) (delaySeconds * 1000000.0F), TimeUnit.MICROSECONDS);
    }
}
