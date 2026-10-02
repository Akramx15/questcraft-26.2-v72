package org.questcraft.veq.client.config;

public enum QuickActionDisplayMode {
    OFF(0),
    SIX(6),
    TWELVE(12);

    private final int visibleSlots;

    QuickActionDisplayMode(int visibleSlots) {
        this.visibleSlots = visibleSlots;
    }

    public int visibleSlots() {
        return visibleSlots;
    }

    public QuickActionDisplayMode next() {
        return switch (this) {
            case OFF -> SIX;
            case SIX -> TWELVE;
            case TWELVE -> OFF;
        };
    }
}
