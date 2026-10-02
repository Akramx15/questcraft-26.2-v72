package org.questcraft.veq.client.overlay;

/** Reentrancy guard for the cancel-only container gesture path. */
public final class ContainerPointerCancelGuard {
    private boolean cancelling;

    public boolean cancel(Runnable releaseScreenWidgets, Runnable resetContainerGesture) {
        if (cancelling || releaseScreenWidgets == null || resetContainerGesture == null) {
            return false;
        }
        cancelling = true;
        try {
            releaseScreenWidgets.run();
            return true;
        } finally {
            resetContainerGesture.run();
            cancelling = false;
        }
    }

    public boolean isCancelling() {
        return cancelling;
    }
}
