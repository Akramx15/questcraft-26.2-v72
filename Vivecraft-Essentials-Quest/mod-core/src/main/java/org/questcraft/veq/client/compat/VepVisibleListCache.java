package org.questcraft.veq.client.compat;

import java.util.ArrayList;
import java.util.List;
import java.util.function.Predicate;

/**
 * Reuses an immutable visible-item snapshot until membership or order changes.
 * Callers own synchronization; this class deliberately has no locks or game
 * dependencies so its allocation behavior can be verified on the host.
 */
final class VepVisibleListCache<T> {
    private final List<T> working = new ArrayList<>();
    private List<T> snapshot = List.of();
    private long revision;

    List<T> refresh(Iterable<T> candidates, Predicate<? super T> visible) {
        int visibleIndex = 0;
        boolean changed = false;
        for (T candidate : candidates) {
            if (!visible.test(candidate)) {
                continue;
            }
            if (visibleIndex == working.size()) {
                working.add(candidate);
                changed = true;
            } else if (working.get(visibleIndex) != candidate) {
                working.set(visibleIndex, candidate);
                changed = true;
            }
            visibleIndex++;
        }
        while (working.size() > visibleIndex) {
            working.remove(working.size() - 1);
            changed = true;
        }
        if (changed) {
            snapshot = List.copyOf(working);
            revision++;
        }
        return snapshot;
    }

    long revision() {
        return revision;
    }
}
