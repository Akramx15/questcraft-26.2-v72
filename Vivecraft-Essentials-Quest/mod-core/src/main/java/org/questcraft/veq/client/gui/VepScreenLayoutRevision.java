package org.questcraft.veq.client.gui;

/** Tracks the primitive inputs that can alter a wrist surface rectangle. */
final class VepScreenLayoutRevision {
    private int left;
    private int top;
    private int width;
    private int height;
    private long featureRevision;
    private int visibleEffectCount;
    private long utilityRevision;
    private int layoutFlags;
    private long revision;
    private boolean initialized;

    long update(int left,
                int top,
                int width,
                int height,
                long featureRevision,
                int visibleEffectCount,
                long utilityRevision,
                int layoutFlags) {
        if (!initialized
                || this.left != left
                || this.top != top
                || this.width != width
                || this.height != height
                || this.featureRevision != featureRevision
                || this.visibleEffectCount != visibleEffectCount
                || this.utilityRevision != utilityRevision
                || this.layoutFlags != layoutFlags) {
            this.left = left;
            this.top = top;
            this.width = width;
            this.height = height;
            this.featureRevision = featureRevision;
            this.visibleEffectCount = visibleEffectCount;
            this.utilityRevision = utilityRevision;
            this.layoutFlags = layoutFlags;
            this.revision++;
            this.initialized = true;
        }
        return revision;
    }
}
