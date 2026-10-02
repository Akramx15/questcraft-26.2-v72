package pojlib;

import org.junit.Test;

import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;

import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertTrue;

public class Fabric262DependencyPinSourceIntegrationTest {
    private static final String LOADER_PIN =
            "private static final String FABRIC_LOADER_26_2 = \"0.19.5\";";
    private static final String FABRIC_API_VERSION = "\"version\": \"0.160.0+26.2\"";
    private static final String FABRIC_API_VERSION_ID = "/versions/UWwhUX3k/";
    private static final String FABRIC_API_SHA256 =
            "5F3DFF88E1661166E222213302B25ACE6C36DC3683804CBD4B5ACF93138EA05E";
    private static final String SODIUM_VERSION = "mc26.2-0.9.2-beta.1-fabric";
    private static final String SODIUM_VERSION_ID = "/versions/A0IzDzaH/";
    private static final String SODIUM_SHA256 =
            "6652B40EE7F0F6D146C668CD288F861D271BC935C12F767D33B6B07BDCB7857A";

    @Test
    public void instanceCreationAndInstallerUseTheSameLatestStableLoader() throws Exception {
        String handler = read("src/main/java/pojlib/InstanceHandler.java");
        String installer = read("src/main/java/pojlib/install/Installer.java");

        assertTrue(handler.contains(LOADER_PIN));
        assertTrue(installer.contains(LOADER_PIN));
        assertFalse(handler.contains("FABRIC_LOADER_26_2 = \"0.19.4\""));
        assertFalse(installer.contains("FABRIC_LOADER_26_2 = \"0.19.4\""));
    }

    @Test
    public void allBundledCatalogCopiesPinTheVerifiedFabricApiArtifact() throws Exception {
        assertCatalog("mods.json");
        assertCatalog("devmods.json");
        assertCatalog("src/main/assets/mods.json");
        assertCatalog("src/main/assets/devmods.json");
    }

    @Test
    public void matchingMinecraftClientIsNotDeletedAndDownloadedAgain() throws Exception {
        String installer = read("src/main/java/pojlib/install/Installer.java");

        assertTrue(installer.contains(
                "else if (!DownloadUtils.compareSHA1(clientFile, " +
                        "minecraftVersionInfo.downloads.client.sha1))"));
        assertFalse(installer.contains(
                "else if (DownloadUtils.compareSHA1(clientFile, " +
                        "minecraftVersionInfo.downloads.client.sha1))"));
    }

    private static void assertCatalog(String relative) throws Exception {
        String catalog = read(relative);
        assertTrue(relative, catalog.contains(FABRIC_API_VERSION));
        assertTrue(relative, catalog.contains(FABRIC_API_VERSION_ID));
        assertTrue(relative, catalog.contains(FABRIC_API_SHA256));
        assertTrue(relative, catalog.contains(SODIUM_VERSION));
        assertTrue(relative, catalog.contains(SODIUM_VERSION_ID));
        assertTrue(relative, catalog.contains(SODIUM_SHA256));
    }

    private static String read(String relative) throws Exception {
        Path direct = Paths.get(relative);
        Path source = Files.exists(direct) ? direct : Paths.get("Pojlib").resolve(relative);
        return new String(Files.readAllBytes(source), StandardCharsets.UTF_8);
    }
}
