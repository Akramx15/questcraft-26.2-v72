package pojlib.util.json;

import org.junit.Test;

import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertTrue;
import static org.junit.Assert.fail;

public class SeedOnlyModManagementTest {
    @Test
    public void legacyInstanceIsNotImplicitlyClaimedWithoutPersonalContext() {
        MinecraftInstances.Instance instance = new MinecraftInstances.Instance();
        instance.versionName = "26.2";

        assertTrue(instance.isPersonalSeedOnlyProfile(
                MinecraftInstances.Instance.PERSONAL_PACKAGE));
        assertFalse(instance.isPersonalSeedOnlyProfile("com.qcxr.qcxr.canary262"));
        assertFalse(instance.isPersonalSeedOnlyProfile("com.qcxr.qcxr"));
    }

    @Test
    public void newProfileSeedsOnceThenPreservesEveryUserChange() throws Exception {
        MinecraftInstances.Instance instance = new MinecraftInstances.Instance();
        instance.versionName = "26.2";
        instance.gameDir = ".";
        instance.enableSeedOnlyModManagement();
        instance.instanceSetupFailed = Boolean.FALSE;
        instance.instanceSetupInProgress = Boolean.FALSE;

        assertTrue(instance.usesSeedOnlyModManagement());
        assertFalse(instance.managedModsSeeded);
        assertTrue(instance.needsInitialManagedSeed(
                MinecraftInstances.Instance.PERSONAL_PACKAGE));
        assertFalse(instance.preservesUserManagedMods(
                MinecraftInstances.Instance.PERSONAL_PACKAGE));

        instance.managedModsSeeded = Boolean.TRUE;
        instance.managedModsSeedRoot = new java.io.File(instance.gameDir).getCanonicalPath();
        assertTrue(instance.preservesUserManagedMods(
                MinecraftInstances.Instance.PERSONAL_PACKAGE));
        assertFalse(instance.needsInitialManagedSeed(
                MinecraftInstances.Instance.PERSONAL_PACKAGE));

        instance.managedModsSeedRoot = instance.managedModsSeedRoot + "-copied";
        assertFalse(instance.preservesUserManagedMods(
                MinecraftInstances.Instance.PERSONAL_PACKAGE));
        assertFalse(instance.needsInitialManagedSeed(
                MinecraftInstances.Instance.PERSONAL_PACKAGE));
    }

    @Test
    public void serializedSeedStateNeverAuthorizesLabOrOtherPackages() throws Exception {
        MinecraftInstances.Instance instance = new MinecraftInstances.Instance();
        instance.versionName = "26.2";
        instance.gameDir = ".";
        instance.enableSeedOnlyModManagement();
        instance.managedModsSeeded = Boolean.TRUE;
        instance.managedModsSeedRoot = new java.io.File(instance.gameDir).getCanonicalPath();

        assertFalse(instance.preservesUserManagedMods("com.qcxr.qcxr.canary262"));
        assertFalse(instance.preservesUserManagedMods((String) null));
    }

    @Test
    public void unknownOrMismatchedMetadataCanNeverAutoSeed() {
        MinecraftInstances.Instance instance = new MinecraftInstances.Instance();
        instance.versionName = "26.2";
        instance.gameDir = ".";

        assertFalse(instance.needsInitialManagedSeed(
                MinecraftInstances.Instance.PERSONAL_PACKAGE));

        instance.enableSeedOnlyModManagement();
        assertFalse(instance.needsInitialManagedSeed(
                MinecraftInstances.Instance.PERSONAL_PACKAGE));
        instance.managedModsSeedRoot = "unexpected-root";
        assertFalse(instance.needsInitialManagedSeed(
                MinecraftInstances.Instance.PERSONAL_PACKAGE));

        instance.managedModsSeedRoot = null;
        instance.instanceSetupFailed = Boolean.TRUE;
        assertFalse(instance.needsInitialManagedSeed(
                MinecraftInstances.Instance.PERSONAL_PACKAGE));

        instance.instanceSetupFailed = Boolean.FALSE;
        instance.instanceSetupInProgress = Boolean.TRUE;
        assertFalse(instance.needsInitialManagedSeed(
                MinecraftInstances.Instance.PERSONAL_PACKAGE));
    }

    @Test
    public void projectArtifactUsesOneExtensionAndRejectsTraversal() throws Exception {
        MinecraftInstances.Instance instance = new MinecraftInstances.Instance();
        instance.gameDir = new java.io.File("profile").getPath();
        ProjectInfo project = new ProjectInfo();
        project.slug = "Example";
        project.fileName = "example.jar";
        project.type = "mod";

        assertEquals("example.jar", instance.resolveProjectArtifact(project).getName());

        project.fileName = null;
        assertEquals("Example.jar", instance.resolveProjectArtifact(project).getName());

        project.fileName = "../escape.jar";
        try {
            instance.resolveProjectArtifact(project);
            fail("Traversal must be rejected");
        } catch(IOException expected) {
            // Expected.
        }
    }

    @Test
    public void existingArtifactRecognizesLegacyDoubleExtension() throws Exception {
        Path profile = Files.createTempDirectory("seed-only-artifact-");
        Path mods = Files.createDirectories(profile.resolve("mods"));
        MinecraftInstances.Instance instance = new MinecraftInstances.Instance();
        instance.gameDir = profile.toString();
        ProjectInfo project = new ProjectInfo();
        project.slug = "Example";
        project.fileName = "example.jar";
        project.type = "mod";

        Path legacy = Files.createFile(mods.resolve("example.jar.jar"));
        assertEquals(legacy.toFile().getCanonicalFile(),
                instance.resolveExistingProjectArtifact(project).getCanonicalFile());

        Path canonical = Files.createFile(mods.resolve("example.jar"));
        try {
            instance.resolveExistingProjectArtifact(project);
            fail("Ambiguous canonical and legacy artifacts must be rejected");
        } catch(IOException expected) {
            // Expected.
        } finally {
            Files.deleteIfExists(canonical);
            Files.deleteIfExists(legacy);
            Files.deleteIfExists(mods);
            Files.deleteIfExists(profile);
        }
    }
}
