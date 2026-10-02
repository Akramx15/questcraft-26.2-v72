package org.questcraft.veq.client.overlay;

import java.util.Objects;

/** Exact-screen scope that defers an external container's carried-item extraction. */
public final class ContextualContainerRenderPass {
    private static final ThreadLocal<Object> DEFERRED_CARRIED_SCREEN = new ThreadLocal<>();

    private ContextualContainerRenderPass() {
    }

    public static void withCarriedDeferred(Object screen, Runnable baseRender) {
        Objects.requireNonNull(screen, "screen");
        Objects.requireNonNull(baseRender, "baseRender");
        Object previous = DEFERRED_CARRIED_SCREEN.get();
        DEFERRED_CARRIED_SCREEN.set(screen);
        try {
            baseRender.run();
        } finally {
            if (previous == null) {
                DEFERRED_CARRIED_SCREEN.remove();
            } else {
                DEFERRED_CARRIED_SCREEN.set(previous);
            }
        }
    }

    public static boolean isCarriedDeferred(Object screen) {
        return screen != null && DEFERRED_CARRIED_SCREEN.get() == screen;
    }
}
