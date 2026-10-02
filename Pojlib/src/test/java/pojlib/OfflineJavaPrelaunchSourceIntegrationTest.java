package pojlib;

import org.junit.Test;

import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;

import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertTrue;

public class OfflineJavaPrelaunchSourceIntegrationTest {
    @Test
    public void offlinePathPreparesAndValidatesEnvironmentBeforeNativeLoad() throws Exception {
        String jre = source("src/main/java/pojlib/util/JREUtils.java");
        int start = jre.indexOf("public static boolean prelaunchOfflineCheck(");
        int end = jre.indexOf("public static int launchJavaVM(", start);
        String body = jre.substring(start, end);

        int validate = body.indexOf("InstalledJavaRuntime.validate(");
        int relocate = body.indexOf("relocateLibPath(activity, instance)");
        int environment = body.indexOf("setJavaEnvironment(activity, instance)");
        int compatibility = body.indexOf("refreshOfflineLaunchCompatibilityAssets(activity, instance)");
        int nativeLoad = body.indexOf("return initJavaRuntime()");
        assertTrue(validate >= 0);
        assertTrue(relocate > validate);
        assertTrue(environment > relocate);
        assertTrue(compatibility > environment);
        assertTrue(nativeLoad > compatibility);
        assertFalse(body.contains("MinecraftMeta"));
        assertFalse(body.contains("installJVM"));
        assertFalse(body.contains("Download"));
    }

    @Test
    public void apiUsesOfflinePreparationInsteadOfBareDlopen() throws Exception {
        String api = source("src/main/java/pojlib/API.java");
        int offline = api.indexOf("Skipping most prelaunch checks due to no WiFi connection.");
        int end = api.indexOf("DownloadManager.reset();", offline);
        String branch = api.substring(offline, end);
        assertTrue(branch.contains("JREUtils.prelaunchOfflineCheck(activity, instance)"));
        assertFalse(branch.contains("JREUtils.initJavaRuntime()"));
    }

    @Test
    public void offlineCompatibilityEntryPointHasNoNetworkCall() throws Exception {
        String installer = source("src/main/java/pojlib/install/Installer.java");
        int start = installer.indexOf("public static boolean refreshOfflineLaunchCompatibilityAssets(");
        int end = installer.indexOf("private static void refreshLocalLaunchCompatibilityAssets(", start);
        String body = installer.substring(start, end);
        assertTrue(body.contains("UnityPlayerActivity.installLWJGL(activity)"));
        assertTrue(body.contains("refreshLocalLaunchCompatibilityAssets(activity, instance)"));
        assertFalse(body.contains("refreshFabricLoaderForCurrentLaunch"));
        assertFalse(body.contains("DownloadUtils"));
        assertFalse(body.contains("FabricMeta"));
    }

    private static String source(String relative) throws Exception {
        Path path = Path.of(relative);
        if(!Files.exists(path)) {
            path = Path.of("Pojlib").resolve(relative);
        }
        return new String(Files.readAllBytes(path), StandardCharsets.UTF_8);
    }
}
