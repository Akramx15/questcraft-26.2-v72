package org.questcraft.veq.client.radial;

import org.vivecraft.client_vr.provider.ControllerType;

/** Public VEQ facade for the independently rendered Grip hotbar surface. */
public final class RadialHotbarController {
    private RadialHotbarController() {
    }

    public static void install() {
        GripHotbarOverlay.install();
    }

    public static void tick() {
        GripHotbarOverlay.tick();
    }

    public static boolean open(ControllerType controller) {
        return GripHotbarOverlay.requestOpen(controller);
    }

    public static void cancel() {
        GripHotbarOverlay.cancel();
    }

    public static boolean owns(ControllerType controller) {
        return GripHotbarOverlay.ownsSession(controller);
    }
}
