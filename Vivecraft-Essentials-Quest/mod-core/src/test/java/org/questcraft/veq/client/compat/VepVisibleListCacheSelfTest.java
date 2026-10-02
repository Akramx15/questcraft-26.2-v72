package org.questcraft.veq.client.compat;

import java.util.List;

public final class VepVisibleListCacheSelfTest {
    private VepVisibleListCacheSelfTest() {
    }

    public static void main(String[] args) {
        VepVisibleListCache<TestAction> cache = new VepVisibleListCache<>();
        TestAction first = new TestAction(true);
        TestAction second = new TestAction(false);
        TestAction third = new TestAction(true);
        List<TestAction> candidates = List.of(first, second, third);

        List<TestAction> visible = cache.refresh(candidates, action -> action.visible);
        require(visible.equals(List.of(first, third)), "visible order changed");
        long initialRevision = cache.revision();
        require(initialRevision > 0L, "first visible snapshot did not publish a revision");

        List<TestAction> reused = cache.refresh(candidates, action -> action.visible);
        require(reused == visible, "unchanged membership allocated a new snapshot");
        require(cache.revision() == initialRevision, "unchanged membership changed revision");

        second.visible = true;
        List<TestAction> expanded = cache.refresh(candidates, action -> action.visible);
        require(expanded.equals(candidates), "dynamic visibility was not refreshed");
        require(expanded != visible, "changed membership reused a stale immutable snapshot");
        require(cache.revision() == initialRevision + 1L,
                "visibility change did not advance revision once");
        require(visible.equals(List.of(first, third)),
                "published immutable snapshot was mutated in place");

        TestAction replacement = new TestAction(true);
        List<TestAction> replaced = cache.refresh(
                List.of(first, replacement, third), action -> action.visible);
        require(replaced.equals(List.of(first, replacement, third)),
                "same-sized replacement was not observed");
        require(cache.revision() == initialRevision + 2L,
                "same-sized membership replacement did not invalidate layout");

        List<TestAction> empty = cache.refresh(List.of(), action -> action.visible);
        require(empty.isEmpty(), "removed actions remained visible");
        require(cache.refresh(List.of(), action -> action.visible) == empty,
                "stable empty membership allocated a new snapshot");
    }

    private static void require(boolean condition, String message) {
        if (!condition) {
            throw new AssertionError(message);
        }
    }

    private static final class TestAction {
        private boolean visible;

        private TestAction(boolean visible) {
            this.visible = visible;
        }
    }
}
