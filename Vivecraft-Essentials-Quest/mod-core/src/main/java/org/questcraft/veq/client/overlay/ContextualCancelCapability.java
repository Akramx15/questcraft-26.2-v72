package org.questcraft.veq.client.overlay;

import net.minecraft.client.gui.screens.inventory.AbstractContainerScreen;
import net.minecraft.client.input.MouseButtonEvent;

import java.lang.reflect.Method;

/** Fail-closed capability check for contextual screens with release-only latches. */
public final class ContextualCancelCapability {
    private static final String NO_OWNER = "";
    private static final ClassValue<Owners> OWNERS = new ClassValue<>() {
        @Override
        protected Owners computeValue(Class<?> type) {
            return new Owners(
                    declaringOwner(type, "mouseReleased", MouseButtonEvent.class),
                    declaringOwner(type, "veq$cancelOwnedPointerGesture")
            );
        }
    };

    private ContextualCancelCapability() {
    }

    public static boolean isSafe(AbstractContainerScreen<?> screen) {
        if (screen == null) {
            return false;
        }
        Owners owners = OWNERS.get(screen.getClass());
        return isSafeReleaseOwner(
                owners.releaseOwner(),
                owners.cancelHookOwner(),
                screen instanceof ContainerPointerCancellation,
                screen instanceof VeqOwnedPointerCancellation
        );
    }

    static boolean isSafeReleaseOwner(String releaseOwner,
                                      String cancelHookOwner,
                                      boolean hasBaseCancelBridge,
                                      boolean hasOwnedCancelCapability) {
        if (!hasBaseCancelBridge || releaseOwner == null || releaseOwner.isEmpty()) {
            return false;
        }
        if (AbstractContainerScreen.class.getName().equals(releaseOwner)) {
            return true;
        }
        // A subclass override is safe only when that exact release owner also
        // supplies the cancel-only hook. Inheriting a hook from Loom/Creative,
        // then adding a new release latch in a modded subclass, fails closed.
        return hasOwnedCancelCapability && releaseOwner.equals(cancelHookOwner);
    }

    private static String declaringOwner(Class<?> type,
                                         String methodName,
                                         Class<?>... parameterTypes) {
        try {
            Method method = type.getMethod(methodName, parameterTypes);
            return method.getDeclaringClass().getName();
        } catch (NoSuchMethodException exception) {
            return NO_OWNER;
        }
    }

    private record Owners(String releaseOwner, String cancelHookOwner) {
    }
}
