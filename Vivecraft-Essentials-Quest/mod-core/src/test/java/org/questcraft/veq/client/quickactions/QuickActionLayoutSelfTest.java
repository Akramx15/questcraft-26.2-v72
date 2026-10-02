package org.questcraft.veq.client.quickactions;

import java.util.HashSet;

public final class QuickActionLayoutSelfTest {
    private QuickActionLayoutSelfTest() {
    }

    public static void main(String[] args) {
        require(QuickActionLayout.positions(0, 100, 100).isEmpty(), "off layout");
        verify(6);
        verify(12);
        boolean rejected = false;
        try {
            QuickActionLayout.positions(7, 100, 100);
        } catch (IllegalArgumentException expected) {
            rejected = true;
        }
        require(rejected, "invalid count accepted");
    }

    private static void verify(int count) {
        var positions = QuickActionLayout.positions(count, 160, 120);
        require(positions.size() == count, "wrong count " + count);
        var unique = new HashSet<String>();
        for (var position : positions) {
            require(position.size() == 24, "wrong button size");
            require(unique.add(position.x() + ":" + position.y()), "overlapping origin");
        }
    }

    private static void require(boolean condition, String message) {
        if (!condition) {
            throw new AssertionError(message);
        }
    }
}
