package org.questcraft.veq.client.overlay;

/**
 * Identity-keyed cache for one external surface's resolved bounds. The active
 * content and its Minecraft Screen are intentionally separate keys because a
 * content adapter may retain its identity while replacing the native screen.
 */
final class VepSurfaceBoundsCache<T> {
    private Object content;
    private Object screen;
    private int scaledWidth;
    private int scaledHeight;
    private long layoutRevision;
    private T value;
    private boolean valid;

    boolean matches(Object content,
                    Object screen,
                    int scaledWidth,
                    int scaledHeight,
                    long layoutRevision) {
        boolean matches = valid
                && this.content == content
                && this.screen == screen
                && this.scaledWidth == scaledWidth
                && this.scaledHeight == scaledHeight
                && this.layoutRevision == layoutRevision;
        return matches;
    }

    T value() {
        if (!valid) {
            throw new IllegalStateException("Surface bounds cache is empty");
        }
        return value;
    }

    void store(Object content,
               Object screen,
               int scaledWidth,
               int scaledHeight,
               long layoutRevision,
               T value) {
        if (value == null) {
            throw new IllegalArgumentException("Surface bounds cannot be null");
        }
        this.content = content;
        this.screen = screen;
        this.scaledWidth = scaledWidth;
        this.scaledHeight = scaledHeight;
        this.layoutRevision = layoutRevision;
        this.value = value;
        this.valid = true;
    }

    void invalidate() {
        content = null;
        screen = null;
        value = null;
        valid = false;
    }
}
