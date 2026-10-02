package org.questcraft.veq.client.overlay;

/**
 * Identity-safe ownership for Minecraft's single carried cursor stack.
 *
 * <p>Ownership is intentionally per controller, not per pair of hands. It is
 * retained across pointer/tracking loss while the exact screen and menu still
 * carry an item, and is never transferred merely because another controller
 * becomes visible.</p>
 */
public final class CarriedPointerOwnership<S, M, C> {
    private S screen;
    private M menu;
    private C controller;

    public void refresh(S currentScreen, M currentMenu, boolean carrying) {
        if (!isActive()) {
            return;
        }
        if (screen != currentScreen || menu != currentMenu || !carrying) {
            clear();
        }
    }

    public boolean retainOrCapture(S currentScreen,
                                   M currentMenu,
                                   C gestureController,
                                   boolean carrying) {
        refresh(currentScreen, currentMenu, carrying);
        if (!carrying || currentScreen == null || currentMenu == null || gestureController == null) {
            return false;
        }
        if (isActive()) {
            // Never transfer a live vanilla cursor to the other hand.
            return screen == currentScreen && menu == currentMenu;
        }
        screen = currentScreen;
        menu = currentMenu;
        controller = gestureController;
        return true;
    }

    /**
     * Reconciles ownership synchronously after an accepted pointer-down has
     * changed the menu's carried stack. A newly picked-up stack is pinned to
     * the controller that caused that exact click before the other controller
     * can be processed. An accepted outside drop clears ownership immediately.
     *
     * @return {@code true} only when the gesture controller owns the carried
     * stack after reconciliation
     */
    public boolean pinAfterAcceptedPress(S currentScreen,
                                         M currentMenu,
                                         C gestureController,
                                         boolean carrying) {
        refresh(currentScreen, currentMenu, carrying);
        if (!carrying) {
            return false;
        }
        retainOrCapture(currentScreen, currentMenu, gestureController, true);
        return owns(currentScreen, currentMenu, gestureController);
    }

    public boolean owns(S currentScreen, M currentMenu, C candidate) {
        return isActive()
                && screen == currentScreen
                && menu == currentMenu
                && controller == candidate;
    }

    public boolean isActive() {
        return screen != null;
    }

    public S screen() {
        return screen;
    }

    public M menu() {
        return menu;
    }

    public C controller() {
        return controller;
    }

    public void clear() {
        screen = null;
        menu = null;
        controller = null;
    }
}
