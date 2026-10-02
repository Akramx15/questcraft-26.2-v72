package org.questcraft.veq.client.overlay;

/**
 * The only adapter between VEQ's renderer-agnostic feature layer and
 * Vivecraft's multi-surface registry.
 *
 * <p>The wrist owns a retained content target and one presentation target.
 * Its pointer and Minecraft's carried stack are composed in ordered strata on
 * the presentation texture, so the headset still receives one quad and never
 * gets two coplanar layers fighting for the same pixels.</p>
 */
public final class VepMultiSurfaceAdapter {
    private static VepWristOverlayView wristView;
    private static VepContextualContainerRuntime contextualRuntime;

    private VepMultiSurfaceAdapter() {
    }

    public static synchronized void install() {
        if (wristView != null) {
            return;
        }
        VepWristOverlayView view = new VepWristOverlayView();
        WristOverlayHandler.installView(view);
        VepContextualContainerRuntime contextual = new VepContextualContainerRuntime(
                view.featureLayer()
        );
        wristView = view;
        contextualRuntime = contextual;
    }

    public static synchronized void tickContextualContainer() {
        if (wristView != null) {
            wristView.featureLayer().tick();
        }
        if (contextualRuntime != null) {
            contextualRuntime.tick();
        }
    }

    static synchronized void uninstallForTests() {
        WristOverlayHandler.forceHide();
        if (contextualRuntime != null) {
            contextualRuntime.close();
            contextualRuntime = null;
        }
        wristView = null;
    }
}
