package org.vmstudio.essentials.core.client.gui.screens;

/** Regression coverage for allocation-reusing wrist render state. */
public final class VRInvRenderScratchSelfTest {
    private VRInvRenderScratchSelfTest() {
    }

    public static void main(String[] args) {
        verifyStatusSnapshotReuse();
        verifyIndexedValueCache();
    }

    private static void verifyStatusSnapshotReuse() {
        VRInvScreen.StatusSnapshot snapshot = new VRInvScreen.StatusSnapshot();
        VRInvScreen.StatusSnapshot first = snapshot.update(
                20.0F, 17.5F, 2.0F, 15, 4.5F, 8, 32, 0.25F
        );
        require(first == snapshot,
                "the status capture must reuse its screen-owned snapshot");
        requireFloat(20.0F, first.maximumHealth(), "maximum health");
        requireFloat(17.5F, first.health(), "health");
        requireFloat(2.0F, first.absorption(), "absorption");
        require(first.hunger() == 15, "hunger must retain the captured value");
        requireFloat(4.5F, first.saturation(), "saturation");
        require(first.armor() == 8, "armor must retain the captured value");
        require(first.experienceLevel() == 32,
                "experience level must retain the captured value");
        requireFloat(0.25F, first.experienceProgress(), "experience progress");

        VRInvScreen.StatusSnapshot second = snapshot.update(
                40.0F, 39.0F, 0.0F, 20, 18.0F, 12, 33, 0.75F
        );
        require(second == first,
                "successive frames must keep the same snapshot identity");
        requireFloat(40.0F, second.maximumHealth(), "updated maximum health");
        requireFloat(39.0F, second.health(), "updated health");
        requireFloat(0.0F, second.absorption(), "updated absorption");
        require(second.hunger() == 20, "updated hunger must replace the old value");
        requireFloat(18.0F, second.saturation(), "updated saturation");
        require(second.armor() == 12, "updated armor must replace the old value");
        require(second.experienceLevel() == 33,
                "updated experience level must replace the old value");
        requireFloat(0.75F, second.experienceProgress(),
                "updated experience progress");
    }

    private static void verifyIndexedValueCache() {
        VRInvScreen.IndexedValueCache<String, Object> cache =
                new VRInvScreen.IndexedValueCache<>(2);
        String firstKey = new String("minecraft:stone");
        Object firstIcon = new Object();

        require(cache.getIfCurrent(0, firstKey) == null,
                "an uninitialized quick-action slot must miss");
        cache.put(0, firstKey, firstIcon);
        require(cache.getIfCurrent(0, firstKey) == firstIcon,
                "the current definition must reuse its icon");
        require(cache.getIfCurrent(0, new String("minecraft:stone")) == firstIcon,
                "an equal immutable definition must reuse the same icon");
        require(cache.getIfCurrent(0, "minecraft:dirt") == null,
                "a changed definition must invalidate the cached icon");

        Object secondIcon = new Object();
        cache.put(0, "minecraft:dirt", secondIcon);
        require(cache.getIfCurrent(0, "minecraft:dirt") == secondIcon,
                "the replacement icon must become current");
        require(cache.getIfCurrent(1, "minecraft:dirt") == null,
                "cache slots must remain independent");

        requireThrows(() -> cache.getIfCurrent(-1, "invalid"),
                "negative indices must retain bounds checks");
        requireThrows(() -> cache.put(2, "invalid", new Object()),
                "upper-bound indices must retain bounds checks");
    }

    private static void requireFloat(float expected, float actual, String label) {
        require(Float.floatToIntBits(expected) == Float.floatToIntBits(actual),
                label + "; expected " + expected + " but got " + actual);
    }

    private static void requireThrows(Runnable action, String message) {
        try {
            action.run();
        } catch (IndexOutOfBoundsException expected) {
            return;
        }
        throw new AssertionError(message);
    }

    private static void require(boolean condition, String message) {
        if (!condition) {
            throw new AssertionError(message);
        }
    }
}
