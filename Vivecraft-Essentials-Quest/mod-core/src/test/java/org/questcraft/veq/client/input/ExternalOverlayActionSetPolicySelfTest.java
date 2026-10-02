package org.questcraft.veq.client.input;

public final class ExternalOverlayActionSetPolicySelfTest {
    private ExternalOverlayActionSetPolicySelfTest() {
    }

    public static void main(String[] args) {
        require(!ExternalOverlayActionSetPolicy.keyboardSetActive(false, false),
                "inactive overlays must not activate the keyboard action set");
        require(ExternalOverlayActionSetPolicy.keyboardSetActive(true, false),
                "the native keyboard overlay must retain its action set");
        require(ExternalOverlayActionSetPolicy.keyboardSetActive(false, true),
                "an external pointer surface must activate handed GUI clicks");
        require(ExternalOverlayActionSetPolicy.keyboardSetActive(true, true),
                "combined ownership must remain active");
        System.out.println("ExternalOverlayActionSetPolicySelfTest PASS");
    }

    private static void require(boolean condition, String message) {
        if (!condition) {
            throw new AssertionError(message);
        }
    }
}
