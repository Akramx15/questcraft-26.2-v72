package org.questcraft.veq.client.overlay;

/**
 * Pure eligibility gate for claiming Minecraft's current container screen.
 * Runtime code supplies the facts; this class deliberately knows nothing
 * about menus, packets, or optional-mod implementations.
 */
public final class ContextualContainerPolicy {
    private ContextualContainerPolicy() {
    }

    public static boolean shouldClaim(boolean featureEnabled,
                                      boolean worldPresent,
                                      boolean playerAlive,
                                      boolean controllersTracked,
                                      boolean isContainerScreen,
                                      boolean isPlayerInventoryScreen,
                                      boolean isCreativeInventoryScreen,
                                      boolean menuMatchesPlayer,
                                      boolean isPlayerInventoryMenu) {
        return featureEnabled
                && worldPresent
                && playerAlive
                && controllersTracked
                && isContainerScreen
                && !isPlayerInventoryScreen
                && !isCreativeInventoryScreen
                && menuMatchesPlayer
                && !isPlayerInventoryMenu;
    }
}
