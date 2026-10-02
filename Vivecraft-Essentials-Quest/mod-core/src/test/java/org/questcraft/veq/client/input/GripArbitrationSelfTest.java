package org.questcraft.veq.client.input;

public final class GripArbitrationSelfTest {
    private GripArbitrationSelfTest() {
    }

    public static void main(String[] args) {
        require(GripArbitration.choose(true, true, true, true) == GripArbitration.Owner.WRIST, "wrist priority");
        require(GripArbitration.choose(false, true, true, true) == GripArbitration.Owner.CLIMBING,
                "climbing priority");
        require(GripArbitration.choose(false, true, false, true) == GripArbitration.Owner.INTERACTION_MODULE,
                "IMC priority");
        require(GripArbitration.choose(false, false, false, true) == GripArbitration.Owner.RADIAL,
                "radial fallback");
        require(GripArbitration.choose(false, false, false, false) == GripArbitration.Owner.NONE,
                "disabled fallback");

        require(!ClimbGripState.claimsGrip(false, false), "idle climbing must not claim Grip");
        require(ClimbGripState.claimsGrip(true, false), "latched climbing claims Grip");
        require(ClimbGripState.claimsGrip(false, true), "enabled climb action claims Grip before latch");
        require(ClimbGripState.claimsGrip(true, true), "combined climb signals claim Grip");
        require(!ClimbGripState.shouldCloseRadial(false, true), "hidden radial stays hidden");
        require(!ClimbGripState.shouldCloseRadial(true, false), "eligible climbing leaves radial open");
        require(ClimbGripState.shouldCloseRadial(true, true), "latch closes an already open radial");
    }

    private static void require(boolean condition, String message) {
        if (!condition) {
            throw new AssertionError(message);
        }
    }
}
