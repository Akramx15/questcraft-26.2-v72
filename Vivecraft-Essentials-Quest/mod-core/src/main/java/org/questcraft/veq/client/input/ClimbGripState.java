package org.questcraft.veq.client.input;

/** Pure ownership rule for the Grip shared by climbing and the radial menu. */
public final class ClimbGripState {
    private ClimbGripState() {
    }

    public static boolean claimsGrip(boolean latchedToClimbable, boolean climbActionEnabled) {
        return latchedToClimbable || climbActionEnabled;
    }

    public static boolean shouldCloseRadial(boolean radialShowing, boolean latchedToClimbable) {
        return radialShowing && latchedToClimbable;
    }
}
