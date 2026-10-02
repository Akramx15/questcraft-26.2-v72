package pojlib;

import org.junit.Test;

import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;

import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertTrue;

public class BundledModPrelaunchSourceIntegrationTest {
    @Test
    public void bundledAssetsReconcileBeforeNetworkProbe() throws Exception {
        String source = readSource("src/main/java/pojlib/API.java");
        int reconcile = source.indexOf("instance.reconcileBundledManagedMods(activity, instances)");
        int probe = source.indexOf("if (hasConnection(activity))", reconcile);
        int connectedUpdate = source.indexOf("instance.updateMods(activity, instances)", probe);

        assertTrue(reconcile >= 0);
        assertTrue(probe > reconcile);
        assertTrue(connectedUpdate > probe);
    }

    @Test
    public void offlineReconcilerHasNoNetworkDependency() throws Exception {
        String source = readSource(
                "src/main/java/pojlib/util/json/BundledManagedModsReconciler.java");
        assertFalse(source.contains("DownloadUtils"));
        assertFalse(source.contains("APIHandler"));
        assertFalse(source.contains("HttpURLConnection"));
        assertFalse(source.contains("http://"));
        assertFalse(source.contains("https://"));
    }

    private static String readSource(String relative) throws Exception {
        Path direct = Paths.get(relative);
        Path source = Files.exists(direct) ? direct : Paths.get("Pojlib").resolve(relative);
        return new String(Files.readAllBytes(source), StandardCharsets.UTF_8);
    }
}
