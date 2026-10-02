package org.questcraft.veq.client.quickactions;

import java.util.ArrayList;
import java.util.List;

/** Pure layout contract shared by the screen and host tests. */
public final class QuickActionLayout {
    private static final int BUTTON_SIZE = 24;
    private static final int GAP = 3;

    private QuickActionLayout() {
    }

    public static List<Position> positions(int count, int centerX, int centerY) {
        if (count != 0 && count != 6 && count != 12) {
            throw new IllegalArgumentException("Quick actions must use 0, 6, or 12 slots");
        }
        List<Position> result = new ArrayList<>(count);
        int perColumn = count <= 6 ? count : 6;
        int firstY = centerY - (perColumn * BUTTON_SIZE + Math.max(0, perColumn - 1) * GAP) / 2;
        for (int i = 0; i < count; i++) {
            boolean left = count <= 6 || i < 6;
            int row = count <= 6 ? i : i % 6;
            int x = centerX + (left ? -122 : 98);
            int y = firstY + row * (BUTTON_SIZE + GAP);
            result.add(new Position(x, y, BUTTON_SIZE));
        }
        return List.copyOf(result);
    }

    public record Position(int x, int y, int size) {
    }
}
