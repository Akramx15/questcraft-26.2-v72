package org.questcraft.veq.client.input;

/** Physical face buttons exposed by the Quest Touch interaction profile. */
public enum QuestFaceButton {
    LEFT_X("/user/hand/left/input/x/click", "X", Hand.LEFT),
    LEFT_Y("/user/hand/left/input/y/click", "Y", Hand.LEFT),
    RIGHT_A("/user/hand/right/input/a/click", "A", Hand.RIGHT),
    RIGHT_B("/user/hand/right/input/b/click", "B", Hand.RIGHT);

    private final String inputPath;
    private final String label;
    private final Hand hand;

    QuestFaceButton(String inputPath, String label, Hand hand) {
        this.inputPath = inputPath;
        this.label = label;
        this.hand = hand;
    }

    public String inputPath() {
        return inputPath;
    }

    public String label() {
        return label;
    }

    public Hand hand() {
        return hand;
    }

    public enum Hand {
        LEFT,
        RIGHT
    }
}
