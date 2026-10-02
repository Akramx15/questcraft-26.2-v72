package org.vivecraft.client_vr.gameplay.screenhandlers;

/**
 * Keeps right-stick world actions suppressed across a native-container close
 * until the physical axis has returned to neutral. This prevents a stick used
 * for GUI scrolling from immediately rotating the world or changing hotbar
 * selection when the GUI action set is replaced by the in-game action set.
 */
public final class NativeContainerAxisLatch {
    private static final int REQUIRED_NEUTRAL_FRAMES = 2;

    private boolean activeLastFrame;
    private boolean suppressWorldAxes;
    private boolean transitioned;
    private boolean entered;
    private boolean exited;
    private boolean guiScrollWasNeutral = true;
    private int neutralFrames;

    public boolean update(boolean containerActive, boolean guiScrollNeutral, boolean worldAxesNeutral) {
        this.transitioned = containerActive != this.activeLastFrame;
        this.entered = this.transitioned && containerActive;
        this.exited = this.transitioned && !containerActive;
        this.activeLastFrame = containerActive;

        if (containerActive) {
            this.suppressWorldAxes = true;
            this.guiScrollWasNeutral = guiScrollNeutral;
            this.neutralFrames = 0;
        } else if (this.exited) {
            // Never release on the action-set transition frame. OpenXR can
            // report a transient zero while replacing GUI with INGAME, even
            // when the physical right stick is still deflected.
            this.neutralFrames = 0;
        } else if (this.suppressWorldAxes) {
            if (worldAxesNeutral) {
                this.neutralFrames++;
                if (this.neutralFrames >= REQUIRED_NEUTRAL_FRAMES) {
                    this.suppressWorldAxes = false;
                }
            } else {
                this.neutralFrames = 0;
            }
        }
        return this.suppressWorldAxes;
    }

    public boolean transitioned() {
        return this.transitioned;
    }

    public boolean entered() {
        return this.entered;
    }

    public boolean exited() {
        return this.exited;
    }

    public boolean guiScrollWasNeutral() {
        return this.guiScrollWasNeutral;
    }

    public boolean isSuppressed() {
        return this.suppressWorldAxes;
    }

    /**
     * Pauses polling without forgetting an in-progress container handoff.
     * This is used for Home/Guardian and temporary OpenXR session loss: a
     * deflected GUI stick must still return to neutral after resume.
     */
    public void suspend() {
        this.transitioned = false;
        this.entered = false;
        this.exited = false;
        this.neutralFrames = 0;
    }

    public void reset() {
        this.activeLastFrame = false;
        this.suppressWorldAxes = false;
        this.transitioned = false;
        this.entered = false;
        this.exited = false;
        this.guiScrollWasNeutral = true;
        this.neutralFrames = 0;
    }
}
