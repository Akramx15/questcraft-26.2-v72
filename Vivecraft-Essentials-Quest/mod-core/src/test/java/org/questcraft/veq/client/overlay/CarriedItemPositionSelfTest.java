package org.questcraft.veq.client.overlay;

public final class CarriedItemPositionSelfTest {
    private CarriedItemPositionSelfTest() {
    }

    public static void main(String[] args) {
        require(CarriedItemPosition.clamp(-20, 0, 504) == 8,
                "left edge keeps the whole item visible");
        require(CarriedItemPosition.clamp(252, 0, 504) == 252,
                "an in-bounds carried item does not move");
        require(CarriedItemPosition.clamp(900, 0, 504) == 496,
                "right edge keeps the whole item visible");
        require(CarriedItemPosition.clamp(0, 0, 10) == 5,
                "tiny surfaces collapse safely to their center");
        require(CarriedItemPosition.clamp(7, 0, 0) == 7,
                "an invalid extent fails closed without overflow");
        require(CarriedItemPosition.clamp(-20, 118, 270) == 126,
                "a cropped wrist clamps to its visible left edge");
        require(CarriedItemPosition.clamp(900, 118, 270) == 380,
                "a cropped wrist clamps to its visible right edge");
        System.out.println("CarriedItemPositionSelfTest PASS");
    }

    private static void require(boolean condition, String message) {
        if (!condition) {
            throw new AssertionError(message);
        }
    }
}
