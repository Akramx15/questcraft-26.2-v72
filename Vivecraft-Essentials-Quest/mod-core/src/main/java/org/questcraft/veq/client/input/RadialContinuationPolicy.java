package org.questcraft.veq.client.input;

/** Pure keep-open rule used for both initial Grip arbitration and re-arbitration. */
final class RadialContinuationPolicy {
    private RadialContinuationPolicy() {
    }

    static boolean keepOpen(
            boolean lifecycleReady,
            boolean tracking,
            boolean wristOwns,
            boolean immersiveOwns,
            boolean climbOwns,
            boolean bowOwns,
            boolean radialEnabled
    ) {
        return lifecycleReady && tracking && radialEnabled &&
                !wristOwns && !immersiveOwns && !climbOwns && !bowOwns;
    }
}
