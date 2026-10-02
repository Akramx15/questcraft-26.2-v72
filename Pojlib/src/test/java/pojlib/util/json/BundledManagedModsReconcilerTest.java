package pojlib.util.json;

import org.junit.Test;
import org.junit.rules.TemporaryFolder;
import org.junit.Rule;

import java.io.File;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.security.MessageDigest;
import java.util.HashMap;
import java.util.Map;

import static org.junit.Assert.assertArrayEquals;
import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertTrue;
import static org.junit.Assert.fail;

public class BundledManagedModsReconcilerTest {
    @Rule public TemporaryFolder temporary = new TemporaryFolder();

    @Test
    public void repairsPinnedCoreAndOptionalAssetWithoutReadingRemoteProjects() throws Exception {
        byte[] coreBytes = "vivecraft-rc6".getBytes(StandardCharsets.UTF_8);
        byte[] veqBytes = "veq-rc6".getBytes(StandardCharsets.UTF_8);
        MinecraftInstances.Instance instance = instance();
        File mods = new File(instance.gameDir, "mods");
        assertTrue(mods.mkdirs());
        Files.write(new File(mods, "Vivecraft.jar").toPath(), "stale".getBytes(StandardCharsets.UTF_8));

        ProjectInfo core = asset("Vivecraft", coreBytes);
        ProjectInfo remote = project("Fabric-API", "https://example.invalid/fabric.jar", null);
        ProjectInfo veq = asset("Vivecraft-Essentials-Quest", veqBytes);
        ModsJson manifest = manifest(core, remote, veq);
        Map<String, byte[]> assets = new HashMap<>();
        assets.put("mods/Vivecraft.bin", coreBytes);
        assets.put("mods/Vivecraft-Essentials-Quest.bin", veqBytes);

        BundledManagedModsReconciler.Outcome outcome =
                BundledManagedModsReconciler.reconcile(instance, manifest, assets::get);

        assertTrue(outcome.artifactsChanged);
        assertTrue(outcome.metadataChanged);
        assertArrayEquals(coreBytes, Files.readAllBytes(new File(mods, "Vivecraft.jar").toPath()));
        assertArrayEquals(veqBytes,
                Files.readAllBytes(new File(mods, "Vivecraft-Essentials-Quest.jar").toPath()));
        assertEquals(2, instance.extProjects.length);
        assertEquals("Vivecraft", instance.extProjects[0].slug);
        assertEquals("Vivecraft-Essentials-Quest", instance.extProjects[1].slug);
        assertFalse(new File(mods, "Fabric-API.jar").exists());
    }

    @Test
    public void explicitlyDisabledOptionalAssetStaysAbsent() throws Exception {
        byte[] coreBytes = "core".getBytes(StandardCharsets.UTF_8);
        byte[] veqBytes = "veq".getBytes(StandardCharsets.UTF_8);
        MinecraftInstances.Instance instance = instance();
        instance.disabledMods = new String[]{"vivecraft-essentials-quest"};
        File mods = new File(instance.gameDir, "mods");
        assertTrue(mods.mkdirs());
        File veqFile = new File(mods, "Vivecraft-Essentials-Quest.jar");
        Files.write(veqFile.toPath(), veqBytes);
        ProjectInfo core = asset("Vivecraft", coreBytes);
        ProjectInfo veq = asset("Vivecraft-Essentials-Quest", veqBytes);
        instance.extProjects = new ProjectInfo[]{veq};
        Map<String, byte[]> assets = new HashMap<>();
        assets.put("mods/Vivecraft.bin", coreBytes);

        BundledManagedModsReconciler.reconcile(
                instance, manifest(core, null, veq), assets::get);

        assertFalse(veqFile.exists());
        assertEquals(1, instance.extProjects.length);
        assertEquals("Vivecraft", instance.extProjects[0].slug);
        assertArrayEquals(new String[]{"vivecraft-essentials-quest"}, instance.disabledMods);
    }

    @Test
    public void corruptBundledCoreFailsBeforeReplacingInstalledCore() throws Exception {
        byte[] expected = "expected".getBytes(StandardCharsets.UTF_8);
        byte[] installed = "known-good-old-core".getBytes(StandardCharsets.UTF_8);
        MinecraftInstances.Instance instance = instance();
        File mods = new File(instance.gameDir, "mods");
        assertTrue(mods.mkdirs());
        File coreFile = new File(mods, "Vivecraft.jar");
        Files.write(coreFile.toPath(), installed);
        ProjectInfo core = asset("Vivecraft", expected);

        try {
            BundledManagedModsReconciler.reconcile(
                    instance,
                    manifest(core, null, null),
                    ignored -> "wrong-apk-bytes".getBytes(StandardCharsets.UTF_8));
            fail("Expected bundled hash mismatch to fail closed");
        } catch(Exception expectedFailure) {
            assertTrue(expectedFailure.getMessage().contains("SHA-256 mismatch"));
        }

        assertArrayEquals(installed, Files.readAllBytes(coreFile.toPath()));
    }

    @Test
    public void remoteRequiredCoreIsRejectedEvenWhenOtherAssetsAreValid() throws Exception {
        MinecraftInstances.Instance instance = instance();
        ProjectInfo core = project(
                "Vivecraft", "https://example.invalid/vivecraft.jar", sha256("remote".getBytes(StandardCharsets.UTF_8)));
        try {
            BundledManagedModsReconciler.reconcile(
                    instance, manifest(core, null, null), ignored -> new byte[0]);
            fail("Expected remote required core to fail closed");
        } catch(Exception expectedFailure) {
            assertTrue(expectedFailure.getMessage().contains("unsafe asset path"));
        }
    }

    private MinecraftInstances.Instance instance() throws Exception {
        MinecraftInstances.Instance instance = new MinecraftInstances.Instance();
        instance.versionName = "26.2";
        instance.instanceName = "26.2";
        instance.gameDir = temporary.newFolder("game").getAbsolutePath();
        instance.defaultMods = true;
        instance.extProjects = new ProjectInfo[0];
        return instance;
    }

    private static ModsJson manifest(ProjectInfo core, ProjectInfo remote, ProjectInfo optional) {
        ModsJson.Version version = new ModsJson.Version();
        version.name = "26.2";
        version.coreMods = remote == null
                ? new ProjectInfo[]{core}
                : new ProjectInfo[]{core, remote};
        version.defaultMods = optional == null
                ? new ProjectInfo[0]
                : new ProjectInfo[]{optional};
        ModsJson result = new ModsJson();
        result.versions = new ModsJson.Version[]{version};
        return result;
    }

    private static ProjectInfo asset(String slug, byte[] contents) throws Exception {
        return project(slug, "asset://mods/" + slug + ".bin", sha256(contents));
    }

    private static ProjectInfo project(String slug, String source, String hash) {
        ProjectInfo project = new ProjectInfo();
        project.slug = slug;
        project.version = "test";
        project.type = "mod";
        project.download_link = source;
        project.sha256 = hash;
        return project;
    }

    private static String sha256(byte[] contents) throws Exception {
        StringBuilder value = new StringBuilder();
        for(byte item : MessageDigest.getInstance("SHA-256").digest(contents)) {
            value.append(String.format("%02x", item & 0xff));
        }
        return value.toString();
    }
}
