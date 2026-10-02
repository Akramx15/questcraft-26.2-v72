package org.questcraft.veq.client.overlay;

import org.vivecraft.client_vr.gameplay.screenhandlers.ExternalScreenOverlayHandler;

/** Host-only regression coverage for carried-stack outside clicks. */
public final class WristPointerPressPolicySelfTest {
    private static final int WIDTH = 504;
    private static final int HEIGHT = 270;

    private WristPointerPressPolicySelfTest() {
    }

    public static void main(String[] args) {
        require(accepts(true, false, false, false, Double.NaN, Double.NaN,
                        true, ExternalScreenOverlayHandler.PointerButton.MIDDLE),
                "focused pointer must retain ordinary middle-click behavior");
        require(accepts(false, true, true, true, 12.0D, 12.0D,
                        false, ExternalScreenOverlayHandler.PointerButton.PRIMARY),
                "exact carried owner must be able to drop a full stack outside content");
        require(accepts(false, true, true, true, 503.0D, 269.0D,
                        false, ExternalScreenOverlayHandler.PointerButton.SECONDARY),
                "exact carried owner must be able to drop one item outside content");

        require(!accepts(false, true, false, true, 12.0D, 12.0D,
                        false, ExternalScreenOverlayHandler.PointerButton.PRIMARY),
                "the other controller must never steal a carried stack");
        require(!accepts(true, true, false, true, 12.0D, 12.0D,
                        true, ExternalScreenOverlayHandler.PointerButton.PRIMARY),
                "active carried ownership must override stale focus on the wrong hand");
        require(!accepts(false, false, false, true, 12.0D, 12.0D,
                        false, ExternalScreenOverlayHandler.PointerButton.PRIMARY),
                "an empty cursor must not gain transparent-surface input");
        require(!accepts(false, true, true, false, 12.0D, 12.0D,
                        false, ExternalScreenOverlayHandler.PointerButton.PRIMARY),
                "invalid coordinates must fail closed");
        require(!accepts(false, true, true, true, Double.NaN, 12.0D,
                        false, ExternalScreenOverlayHandler.PointerButton.PRIMARY),
                "non-finite coordinates must fail closed");
        require(!accepts(false, true, true, true, -0.01D, 12.0D,
                        false, ExternalScreenOverlayHandler.PointerButton.PRIMARY),
                "outside clicks must remain bounded to the finite wrist canvas");
        require(!accepts(false, true, true, true, WIDTH, 12.0D,
                        false, ExternalScreenOverlayHandler.PointerButton.PRIMARY),
                "the exclusive right canvas edge must fail closed");
        require(!accepts(false, true, true, true, 12.0D, HEIGHT,
                        false, ExternalScreenOverlayHandler.PointerButton.PRIMARY),
                "the exclusive bottom canvas edge must fail closed");
        require(!accepts(false, true, true, true, 12.0D, 12.0D,
                        true, ExternalScreenOverlayHandler.PointerButton.PRIMARY),
                "VEP controls and passive extensions must keep their normal click path");
        require(!accepts(false, true, true, true, 12.0D, 12.0D,
                        false, ExternalScreenOverlayHandler.PointerButton.MIDDLE),
                "middle click must not become an outside-drop shortcut");
        require(!accepts(false, true, true, true, 12.0D, 12.0D,
                        false, null),
                "a missing button must fail closed");

        System.out.println("WristPointerPressPolicySelfTest PASS");
    }

    private static boolean accepts(
            boolean focused,
            boolean carrying,
            boolean exactOwner,
            boolean coordinateValid,
            double x,
            double y,
            boolean insideInteraction,
            ExternalScreenOverlayHandler.PointerButton button
    ) {
        return WristPointerPressPolicy.accepts(
                focused,
                carrying,
                exactOwner,
                coordinateValid,
                x,
                y,
                WIDTH,
                HEIGHT,
                insideInteraction,
                button
        );
    }

    private static void require(boolean condition, String message) {
        if (!condition) {
            throw new AssertionError(message);
        }
    }
}
