package pojlib;

import org.junit.Test;

import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;

import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertTrue;

public class SeedOnlyModManagementSourceIntegrationTest {
    @Test
    public void quest262ProfilesAreSeedOnlyFromCreation() throws Exception {
        String source = read("src/main/java/pojlib/InstanceHandler.java");
        assertTrue(source.contains("if(\"26.2\".equals(minecraftVersion) && activity != null"));
        assertTrue(source.contains("MinecraftInstances.Instance.PERSONAL_PACKAGE.equals(activity.getPackageName())"));
        assertTrue(source.contains("instance.enableSeedOnlyModManagement();"));
    }

    @Test
    public void bothPrelaunchReconcilersRespectUserOwnership() throws Exception {
        String source = read("src/main/java/pojlib/util/json/MinecraftInstances.java");
        int bundled = source.indexOf("public boolean reconcileBundledManagedMods");
        int bundledGuard = source.indexOf("if(isPersonalSeedOnlyProfile(ctx))", bundled);
        int completedSeedGuard = source.indexOf("if(preservesUserManagedMods(ctx))", bundledGuard);
        int bundledMutation = source.indexOf("BundledManagedModsReconciler.reconcile", bundled);
        int online = source.indexOf("public boolean updateMods", bundledMutation);
        int onlineGuard = source.indexOf(
                "if(isPersonalSeedOnlyProfile(ctx) && !explicitSeedOrRepair)", online);
        int onlineCompletedSeedGuard = source.indexOf(
                "if(preservesUserManagedMods(ctx))", onlineGuard);
        int manifestDownload = source.indexOf("downloadCurrentModsJson", online);

        assertTrue(bundledGuard > bundled && bundledGuard < bundledMutation);
        assertTrue(completedSeedGuard > bundledGuard && completedSeedGuard < bundledMutation);
        assertTrue(onlineGuard > online && onlineGuard < manifestDownload);
        assertTrue(onlineCompletedSeedGuard > onlineGuard
                && onlineCompletedSeedGuard < manifestDownload);
    }

    @Test
    public void repairIsExplicitAndPersistent() throws Exception {
        String source = read("src/main/java/pojlib/API.java");
        assertTrue(source.contains("public static boolean repairManagedMods("));
        assertTrue(source.contains("instance.repairManagedMods(activity, instances)"));
        assertTrue(source.contains("Explicit managed-mod repair requires a network connection"));
    }

    @Test
    public void migrationRunsBeforeAnyArtifactReconciliation() throws Exception {
        String source = read("src/main/java/pojlib/API.java");
        int migration = source.indexOf("instance.migrateExistingPersonalProfileToSeedOnly(activity, instances)");
        int bundled = source.indexOf("instance.reconcileBundledManagedMods(activity, instances)");
        int online = source.indexOf("instance.updateMods(activity, instances)");

        assertTrue(migration >= 0);
        assertTrue(bundled > migration);
        assertTrue(online > bundled);
    }

    @Test
    public void personalPlaySkipsBothMutatorsAtTheAuthoritativeCallSite() throws Exception {
        String source = read("src/main/java/pojlib/API.java");
        assertTrue(source.contains(
                "boolean userOwnedMods = instance.preservesUserManagedMods(activity);"));
        assertTrue(source.contains("if(personalSeedOnly && !userOwnedMods)"));
        assertTrue(source.contains("if(!instance.needsInitialManagedSeed(activity))"));
        assertTrue(source.contains("Initial Personal mod seed is incomplete"));
        assertTrue(source.contains(
                "if(!userOwnedMods && !instance.reconcileBundledManagedMods(activity, instances))"));
        assertTrue(source.contains(
                "if(!userOwnedMods)"));
        assertTrue(source.contains("instance.updateMods(activity, instances);"));
        assertTrue(source.contains("InstanceHandler.isInstanceCreationActive(instance)"));
    }

    @Test
    public void creationUsesExplicitSeedRatherThanNormalPlayUpdate() throws Exception {
        String source = read("src/main/java/pojlib/InstanceHandler.java");
        assertTrue(source.contains(
                "boolean managedModsReady = instance.isPersonalSeedOnlyProfile(activity)"));
        assertTrue(source.contains("? instance.seedManagedMods(activity, instances)"));
        assertTrue(source.contains(": instance.updateMods(activity, instances)"));
        assertTrue(source.contains("Play will retry or fail closed safely"));
        int callback = source.indexOf("postInstall.accept(instance)");
        int seed = source.indexOf("instance.seedManagedMods(activity, instances)");
        assertTrue(callback >= 0 && seed > callback);
        assertTrue(source.indexOf("instance.seedManagedMods(activity, instances)", seed + 1) < 0);
        assertTrue(source.contains("instance.instanceSetupFailed = Boolean.TRUE;"));
        assertTrue(source.contains("Thread.currentThread().interrupt();"));
        assertTrue(source.contains("ACTIVE_INSTANCE_CREATIONS"));
        assertTrue(source.contains("public static boolean isInstanceCreationActive"));
        assertTrue(source.contains("Recovered an interrupted instance creation"));
        assertTrue(source.contains("FileUtil.unzipArchiveChecked"));
        assertTrue(source.contains(".mrpack-staging"));
        assertTrue(source.contains("if(Files.exists(overridesRoot))"));
        assertTrue(source.contains("Modpack overrides path is not a directory"));
        assertTrue(source.contains("throw exc != null ? exc"));
        assertTrue(source.contains("if(exc != null)"));
        assertTrue(source.contains("CREATION_REGISTRATION_LOCK"));
        int registrationLock = source.indexOf(
                "synchronized(CREATION_REGISTRATION_LOCK)");
        int duplicateRecheck = source.indexOf(
                "sameInstanceTarget(existing, instanceName, targetGameDir)", registrationLock);
        int creatorRegistration = source.indexOf(
                "ACTIVE_INSTANCE_CREATIONS.add(creationKey)", registrationLock);
        int inProgressPersistence = source.indexOf(
                "registrationPersisted = instance.persistMetadataAtomically(instances)");
        assertTrue(registrationLock >= 0 && duplicateRecheck > registrationLock);
        assertTrue(creatorRegistration > duplicateRecheck
                && creatorRegistration < inProgressPersistence);
        assertTrue(source.indexOf(
                "ACTIVE_INSTANCE_CREATIONS.remove(creationKey)",
                inProgressPersistence) > inProgressPersistence);
        assertTrue(source.indexOf(
                "catch(RuntimeException persistenceFailure)",
                inProgressPersistence) > inProgressPersistence);
        int seedStart = source.indexOf("instance.seedManagedMods(activity, instances)");
        int setupComplete = source.indexOf(
                "instance.instanceSetupInProgress = Boolean.FALSE", seedStart);
        assertTrue(seedStart >= 0 && setupComplete > seedStart);
        int completion = source.indexOf("}).whenComplete((unused, failure)");
        int completionFailure = source.indexOf(
                "instance.instanceSetupFailed = Boolean.TRUE", completion);
        int completionRemoval = source.indexOf(
                "ACTIVE_INSTANCE_CREATIONS.remove(creationKey)", completion);
        assertTrue(completionFailure > completion && completionRemoval > completionFailure);
    }

    @Test
    public void explicitRepairPreservesMissingUnmanagedProjects() throws Exception {
        String source = read("src/main/java/pojlib/util/json/MinecraftInstances.java");
        assertTrue(source.contains("boolean preserveMissingUnmanaged"));
        assertTrue(source.contains("!mod.exists() && !preserveMissingUnmanaged"));
        assertTrue(source.contains("return updateMods(ctx, instances, true, true);"));
        assertTrue(source.contains(
                "updateModByType(ctx, mergedNewMods, preserveMissingUnmanaged);"));
        assertTrue(source.contains(
                "if(oldMods != null && !explicitSeedOrRepair"));
        int targetValidation = source.indexOf("if(targetVersion == null)");
        int oldRemoval = source.indexOf("removeOldMods(oldMods, newMods)");
        assertTrue(targetValidation >= 0 && oldRemoval > targetValidation);
        int repair = source.indexOf("public boolean repairManagedMods");
        int repairGuard = source.indexOf("if(!preservesUserManagedMods(ctx))", repair);
        assertTrue(repairGuard > repair);
    }

    @Test
    public void personalModManagerInstallsAndRemovesArtifactsImmediately() throws Exception {
        String handler = read("src/main/java/pojlib/InstanceHandler.java");
        String api = read("src/main/java/pojlib/API.java");
        String ui = read("../QCXR-XR-Wrapper/Assets/Scripts/ModManager.cs");
        String instanceUi = read("../QCXR-XR-Wrapper/Assets/Scripts/InstanceManager.cs");
        assertTrue(handler.contains("return instance.installUserProjects(activity, instances, requested)"));
        assertTrue(handler.contains("return instance.removeUserProject(instances, oldInfo, managedDefault)"));
        assertTrue(api.contains("public static boolean addExtraProjects"));
        assertTrue(api.contains("public static boolean hasInstalledExtraProject"));
        assertTrue(api.contains("Activity activity, MinecraftInstances instances"));
        assertTrue(ui.contains("CallStatic<bool>("));
        assertTrue(ui.contains("\"addExtraProjects\""));
        assertTrue(ui.contains("\"hasInstalledExtraProject\""));
        assertTrue(ui.contains("Could not verify required dependencies"));
        assertTrue(ui.contains("JNIStorage.activity, JNIStorage.instancesObj"));
        assertTrue(instanceUi.contains("JNIStorage.activity"));
        String model = read("src/main/java/pojlib/util/json/MinecraftInstances.java");
        assertTrue(model.contains("item.ownedProject == null && destination.exists()"));
        assertTrue(model.contains("A project update cannot change artifact type"));
    }

    @Test
    public void copiedSeedOnlyMetadataCannotDisableLabCoreProtection() throws Exception {
        String source = read("src/main/java/pojlib/InstanceHandler.java");
        int personalBranch = source.indexOf("if(instance.isPersonalSeedOnlyProfile(activity))");
        int personalReturn = source.indexOf("return instance.removeUserProject", personalBranch);
        int coreGuard = source.indexOf("if(isCoreMod(instance, oldInfo))", personalReturn);
        int deletion = source.indexOf("Files.deleteIfExists", coreGuard);

        assertTrue(personalBranch >= 0);
        assertTrue(personalReturn > personalBranch);
        assertTrue(coreGuard > personalReturn && coreGuard < deletion);
        assertFalse(source.substring(coreGuard, deletion).contains(
                "usesSeedOnlyModManagement"));
    }

    @Test
    public void v72HasAnExactFailClosedPersonalBuildIdentity() throws Exception {
        String entry = read(
                "../QCXR-XR-Wrapper/Assets/Editor/QuestCraftPersonalV72CliBuild.cs");
        String builder = read(
                "../QCXR-XR-Wrapper/Assets/Editor/QuestCraftCliBuild.cs");
        assertTrue(entry.contains("ApplicationIdentifier = \"com.qcxr.qcxr.dev262\""));
        assertTrue(entry.contains("ProductName = \"Vivecraft Stable\""));
        assertTrue(entry.contains(
                "VersionName = \"6.0.1-26.2-vivecraft-personal.13\""));
        assertTrue(entry.contains("VersionCode = \"72\""));
        assertTrue(entry.contains(
                "QuestCraft-Vivecraft-26.2-personal.13-local.apk"));
        assertTrue(entry.contains("QuestCraftCliBuild.BuildAcceptedPersonalV72Android()"));
        assertTrue(builder.contains("BuildAndroidInternal(PersonalBuildIdentity.V72)"));
    }

    private static String read(String relative) throws Exception {
        Path direct = Paths.get(relative);
        Path source = Files.exists(direct) ? direct : Paths.get("Pojlib").resolve(relative);
        return new String(Files.readAllBytes(source), StandardCharsets.UTF_8);
    }
}
