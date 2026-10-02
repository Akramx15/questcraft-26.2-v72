package pojlib.install;

import org.junit.Test;

import java.nio.file.Files;
import java.nio.file.Path;

import static org.junit.Assert.assertTrue;

public class InstallerLaunchCompatibilitySourceTest {
    @Test
    public void migrationFailureDoesNotSkipLoaderAndClasspathRefresh() throws Exception {
        String installer = new String(Files.readAllBytes(
            Path.of("src/main/java/pojlib/install/Installer.java")));

        int connectedRefresh = installer.indexOf(
            "public static void refreshLaunchCompatibilityAssets(");
        int localRefresh = installer.indexOf(
            "refreshLocalLaunchCompatibilityAssets(activity, instance);", connectedRefresh);
        int loaderRefresh = installer.indexOf(
            "refreshFabricLoaderForCurrentLaunch(activity, instance);", localRefresh);
        assertTrue(connectedRefresh >= 0);
        assertTrue(localRefresh > connectedRefresh);
        assertTrue(loaderRefresh > localRefresh);

        int localHelper = installer.indexOf(
            "private static void refreshLocalLaunchCompatibilityAssets(");
        int localHelperEnd = installer.indexOf(
            "private static void migrateVivecraftWeaponCollisionBestEffort", localHelper);
        String localBody = installer.substring(localHelper, localHelperEnd);
        assertTrue(localBody.contains("migrateVivecraftWeaponCollisionBestEffort(instance);"));
        assertTrue(localBody.contains("ensureClasspathEntryFirst(instance, OSHI_ANDROID_SHIM);"));

        int helper = installer.indexOf(
            "private static void migrateVivecraftWeaponCollisionBestEffort");
        int nextMethod = installer.indexOf(
            "private static void migrateInvalid26_2Options", helper);
        String helperBody = installer.substring(helper, nextMethod);
        assertTrue(helperBody.contains("catch (IOException migrationError)"));
        assertTrue(helperBody.contains("continuing launch compatibility refresh"));
    }

    @Test
    public void compatibilityRefreshDoesNotOwnOptionsRepair() throws Exception {
        String installer = new String(Files.readAllBytes(
            Path.of("src/main/java/pojlib/install/Installer.java")));

        int refresh = installer.indexOf(
            "public static void refreshLaunchCompatibilityAssets(");
        int nextMethod = installer.indexOf(
            "public static boolean refreshOfflineLaunchCompatibilityAssets", refresh);
        String refreshBody = installer.substring(refresh, nextMethod);
        assertTrue(refreshBody.contains("refreshLocalLaunchCompatibilityAssets(activity, instance);"));
        assertTrue(!refreshBody.contains("OptionsFileOwnershipRepair"));
    }
}
