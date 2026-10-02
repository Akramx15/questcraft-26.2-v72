package org.questcraft.veq.client.overlay;

import java.util.Objects;

/**
 * Identity-based ownership for one physical pointer press.
 *
 * <p>The screen, controller and button that accepted the down edge remain the
 * only valid release target. A screen transition, controller mismatch or loss
 * of an exact plane coordinate converts the completion into a cancellation;
 * it can never redirect the release to the currently visible screen.</p>
 */
public final class PointerPressOwnership<S, C, B> {
    private S screen;
    private C controller;
    private B button;

    public boolean capture(S screen, C controller, B button, boolean accepted) {
        if (!accepted || screen == null || controller == null || button == null || isActive()) {
            return false;
        }
        this.screen = screen;
        this.controller = controller;
        this.button = button;
        return true;
    }

    public boolean isActive() {
        return screen != null;
    }

    public S screen() {
        return screen;
    }

    public C controller() {
        return controller;
    }

    public B button() {
        return button;
    }

    public Completion<S, C, B> finish(S currentScreen,
                                      C releasingController,
                                      boolean hasExactCoordinates) {
        if (!isActive()) {
            return Completion.none();
        }
        Disposition disposition = screen == currentScreen
                && Objects.equals(controller, releasingController)
                && hasExactCoordinates
                ? Disposition.RELEASE
                : Disposition.CANCEL;
        return complete(disposition);
    }

    public Completion<S, C, B> cancel() {
        return isActive() ? complete(Disposition.CANCEL) : Completion.none();
    }

    private Completion<S, C, B> complete(Disposition disposition) {
        Completion<S, C, B> completion = new Completion<>(
                disposition,
                screen,
                controller,
                button
        );
        screen = null;
        controller = null;
        button = null;
        return completion;
    }

    public enum Disposition {
        NONE,
        RELEASE,
        CANCEL
    }

    public record Completion<S, C, B>(Disposition disposition,
                                      S screen,
                                      C controller,
                                      B button) {
        private static <S, C, B> Completion<S, C, B> none() {
            return new Completion<>(Disposition.NONE, null, null, null);
        }
    }
}
