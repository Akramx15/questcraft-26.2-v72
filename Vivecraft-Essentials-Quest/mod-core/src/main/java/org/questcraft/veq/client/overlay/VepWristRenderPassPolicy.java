package org.questcraft.veq.client.overlay;

/** Allocation-free decision for the wrist pointer/carried-item pass. */
final class VepWristRenderPassPolicy {
    private VepWristRenderPassPolicy() {
    }

    static boolean shouldRun(boolean pointerRenderable, boolean carriedStackPresent) {
        return pointerRenderable || carriedStackPresent;
    }
}
