package org.vmstudio.essentials.core.client.gui;

import org.jetbrains.annotations.NotNull;

/** A narrowly scoped marker for Visor's synthetic jump/crouch key events. */
public final class KeyboardWorldInputScope {
    private static final ThreadLocal<Integer> DEPTH =
            ThreadLocal.withInitial(() -> 0);

    private KeyboardWorldInputScope() {
        throw new UnsupportedOperationException("Utility class");
    }

    public static void run(@NotNull Runnable action) {
        if (!NativeContainerPlacement.isActive()) {
            action.run();
            return;
        }

        int oldDepth = DEPTH.get();
        DEPTH.set(oldDepth + 1);
        try {
            action.run();
        } finally {
            if (oldDepth == 0) {
                DEPTH.remove();
            } else {
                DEPTH.set(oldDepth);
            }
        }
    }

    public static boolean isRouting() {
        return DEPTH.get() > 0 && NativeContainerPlacement.isActive();
    }
}
