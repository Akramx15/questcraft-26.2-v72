package org.vivecraft.client_vr.gameplay.screenhandlers;

/**
 * Turns a GUI action into one fresh close edge for one exact native container.
 *
 * <p>The action set may become active while the physical button that opened a
 * container is still held. Two consecutive active-neutral samples are
 * required before a later press can close it. Inactive samples (Home,
 * Guardian, focus loss, or an action-set handoff) never count as release.</p>
 */
public final class NativeContainerCloseGate {
    static final int REQUIRED_NEUTRAL_SAMPLES = 2;

    private Object screen;
    private Object menu;
    private int neutralSamples;
    private boolean armed;
    private boolean previouslyPressed;

    /**
     * @return true exactly once for a fresh press owned by the same screen and
     * menu identities supplied when the gate was entered
     */
    public boolean update(
        boolean eligible,
        Object screen,
        Object menu,
        boolean actionActive,
        boolean pressed
    ) {
        if (!eligible || screen == null || menu == null) {
            this.clear();
            return false;
        }

        if (this.screen != screen || this.menu != menu) {
            this.screen = screen;
            this.menu = menu;
            // The entry sample is a real sample only while the GUI action set
            // is active. This lets a container opened by L2 arm B after one
            // further neutral tick, while a container opened by held B still
            // has to observe two neutral ticks after release.
            this.neutralSamples = actionActive && !pressed ? 1 : 0;
            this.armed = false;
            this.previouslyPressed = pressed;
            return false;
        }

        if (!actionActive) {
            // Do not treat an inactive action set as evidence of release.
            this.neutralSamples = 0;
            this.armed = false;
            this.previouslyPressed = true;
            return false;
        }

        if (!this.armed) {
            if (pressed) {
                this.neutralSamples = 0;
            } else if (++this.neutralSamples >= REQUIRED_NEUTRAL_SAMPLES) {
                this.armed = true;
            }
            this.previouslyPressed = pressed;
            return false;
        }

        boolean freshPress = pressed && !this.previouslyPressed;
        this.previouslyPressed = pressed;
        if (freshPress) {
            // A single close request owns this context. A still-open or newly
            // replaced screen must complete a new neutral handoff.
            this.armed = false;
            this.neutralSamples = 0;
        }
        return freshPress;
    }

    public boolean owns(Object screen, Object menu) {
        return this.screen == screen && this.menu == menu;
    }

    public boolean isArmed() {
        return this.armed;
    }

    public void clear() {
        this.screen = null;
        this.menu = null;
        this.neutralSamples = 0;
        this.armed = false;
        this.previouslyPressed = false;
    }
}
