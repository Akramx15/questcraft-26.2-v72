package org.vmstudio.essentials.core.client.gui.screens;

import java.util.List;

/** Regression coverage for the allocation-reusing visible-effect render list. */
public final class VRInvEffectCacheSelfTest {
    private VRInvEffectCacheSelfTest() {
    }

    public static void main(String[] args) {
        VRInvEffectInvScreen.SortedVisibleCache<TestEffect> cache =
                new VRInvEffectInvScreen.SortedVisibleCache<>();
        TestEffect slow = new TestEffect(3, true);
        TestEffect hidden = new TestEffect(1, false);
        TestEffect fast = new TestEffect(2, true);
        List<TestEffect> candidates = List.of(slow, hidden, fast);

        List<TestEffect> visible = cache.refresh(
                true,
                candidates,
                TestEffect::visible
        );
        require(visible.equals(List.of(fast, slow)),
                "visible effects must keep natural sorted render order");

        hidden.visible = true;
        List<TestEffect> refreshed = cache.refresh(
                true,
                candidates,
                TestEffect::visible
        );
        require(refreshed == visible,
                "effect refresh must reuse the same scratch list");
        require(refreshed.equals(List.of(hidden, fast, slow)),
                "newly visible effects must join the sorted render order");

        List<TestEffect> disabled = cache.refresh(
                false,
                candidates,
                TestEffect::visible
        );
        require(disabled == visible && disabled.isEmpty(),
                "disabled potion HUD must clear and reuse the scratch list");
    }

    private static void require(boolean condition, String message) {
        if (!condition) {
            throw new AssertionError(message);
        }
    }

    private static final class TestEffect implements Comparable<TestEffect> {
        private final int order;
        private boolean visible;

        private TestEffect(int order, boolean visible) {
            this.order = order;
            this.visible = visible;
        }

        private boolean visible() {
            return visible;
        }

        @Override
        public int compareTo(TestEffect other) {
            return Integer.compare(order, other.order);
        }
    }
}
