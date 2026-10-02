package pojlib;

import android.app.Activity;

import com.google.common.collect.Lists;

import org.apache.commons.io.FileUtils;

import java.io.File;
import java.io.IOException;
import java.nio.file.FileVisitResult;
import java.nio.file.FileVisitor;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.nio.file.StandardCopyOption;
import java.nio.file.attribute.BasicFileAttributes;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Locale;
import java.util.List;
import java.util.Optional;
import java.util.Set;
import java.util.UUID;
import java.util.concurrent.CompletableFuture;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.ExecutionException;
import java.util.concurrent.Future;
import java.util.function.Consumer;

import pojlib.account.MinecraftAccount;
import pojlib.install.FabricMeta;
import pojlib.install.Installer;
import pojlib.install.MinecraftMeta;
import pojlib.install.QuiltMeta;
import pojlib.install.VersionInfo;
import pojlib.util.Constants;
import pojlib.util.FileUtil;
import pojlib.util.VLoader;
import pojlib.util.download.DownloadManager;
import pojlib.util.json.MinecraftInstances;
import pojlib.util.json.ModsJson;
import pojlib.util.json.ProjectInfo;
import pojlib.util.GsonUtils;
import pojlib.util.JREUtils;
import pojlib.util.Logger;
import pojlib.util.json.ModrinthIndexJson;

public class InstanceHandler {
    public static final String MODS = "https://raw.githubusercontent.com/QuestCraftPlusPlus/Pojlib/refs/heads/" + Constants.GIT_BRANCH + "/mods.json";
    public static final String DEV_MODS = "https://raw.githubusercontent.com/QuestCraftPlusPlus/Pojlib/refs/heads/" + Constants.GIT_BRANCH + "/devmods.json";
    // Latest stable loader accepted for the 26.2 Lab stack. Keep this pin in
    // sync with Installer so instance creation and launch use one classpath.
    private static final String FABRIC_LOADER_26_2 = "0.19.5";
    private static final String OPENXR_COPY_BATCH_PROPERTY = "-Dvivecraft.openxrCopyBatch=";
    private static final Set<String> ACTIVE_INSTANCE_CREATIONS =
            ConcurrentHashMap.newKeySet();
    private static final Object CREATION_REGISTRATION_LOCK = new Object();

    /** Runtime half of the durable setup gate used by API prelaunch. */
    public static boolean isInstanceCreationActive(MinecraftInstances.Instance instance) {
        return instance != null && instance.gameDir != null
                && ACTIVE_INSTANCE_CREATIONS.contains(instanceCreationKey(instance.gameDir));
    }

    private static String instanceCreationKey(String gameDir) {
        try {
            return new File(gameDir).getCanonicalPath().toLowerCase(Locale.ROOT);
        } catch(IOException ignored) {
            return new File(gameDir).getAbsoluteFile().toPath().normalize().toString()
                    .toLowerCase(Locale.ROOT);
        }
    }

    private static boolean sameInstanceTarget(
            MinecraftInstances.Instance existing, String instanceName,
            String targetGameDir) {
        return existing != null && ((existing.instanceName != null
                && existing.instanceName.equalsIgnoreCase(instanceName))
                || (existing.gameDir != null && instanceCreationKey(existing.gameDir)
                .equals(instanceCreationKey(targetGameDir))));
    }

    public static MinecraftInstances.Instance create(Activity activity, MinecraftInstances instances, String instanceName, String userHome, String modLoader, String mrpackFilePath, String imageURL) {
        String targetGameDir = Constants.USER_HOME + "/instances/"
                + instanceName.toLowerCase(Locale.ROOT).replaceAll(" ", "_");
        if(instances != null && instances.instances != null) {
            for(MinecraftInstances.Instance existing : instances.instances) {
                if(sameInstanceTarget(existing, instanceName, targetGameDir)) {
                    Logger.getInstance().appendToLog(
                            "Instance " + instanceName + " already exists! Using original instance.");
                    return existing;
                }
            }
        }

        // Never extract a pack over an existing or partially-created profile.
        // Each attempt gets a fresh staging root, so a failed archive cannot
        // lend a stale index or override to a later retry.
        File setupFile = new File(new File(Constants.USER_HOME, ".mrpack-staging"),
                instanceName.toLowerCase(Locale.ROOT).replaceAll(" ", "_")
                        + "-" + UUID.randomUUID());
        File mrpackJson = new File(setupFile, "modrinth.index.json");
        try {
            FileUtil.unzipArchiveChecked(mrpackFilePath, setupFile.getPath());
        } catch(IOException failure) {
            cleanupMrpackStaging(setupFile);
            Logger.getInstance().appendToLog(
                    "Could not extract modpack safely; instance creation aborted: "
                            + failure.getMessage());
            return null;
        }

        ModrinthIndexJson index = GsonUtils.jsonFileToObject(mrpackJson.getAbsolutePath(), ModrinthIndexJson.class);
        if(index == null || index.dependencies == null
                || index.dependencies.minecraft == null
                || index.dependencies.minecraft.trim().isEmpty()
                || index.files == null) {
            cleanupMrpackStaging(setupFile);
            Logger.getInstance().appendToLog(
                    "Couldn't install invalid modpack index at " + mrpackJson.getAbsolutePath());
            return null;
        }

        MinecraftInstances.Instance created;
        try {
            created = create(
                    activity, instances, instanceName, userHome, false,
                    index.dependencies.minecraft, modLoader, imageURL, (instance) -> {
            try {
                if(instance.extProjects == null) {
                    instance.extProjects = new ProjectInfo[0];
                }
                ArrayList<ProjectInfo> mods = Lists.newArrayList(instance.extProjects);
                for(ModrinthIndexJson.ModpackFile file : index.files) {
                    if(file != null && file.path != null && file.path.contains("mods")) {
                        if(file.downloads == null || file.downloads.length == 0
                                || file.downloads[0] == null
                                || !file.downloads[0].startsWith("https://")) {
                            throw new IOException(
                                    "Modpack mod has no safe download URL: " + file.path);
                        }
                        ProjectInfo info = new ProjectInfo();
                        info.slug = file.path
                                .replaceAll(".*/", "")
                                .replaceAll("\\..*", "");
                        info.version = "1.0.0";
                        info.download_link = file.downloads[0];
                        info.type = "mod";
                        if(isCoreMod(instance, info)) {
                            continue;
                        }

                        mods.add(info);
                    }
                }
                instance.extProjects = mods.toArray(new ProjectInfo[0]);
                Path overridesRoot = Paths.get(setupFile + "/overrides");
                if(Files.exists(overridesRoot)) {
                    if(!Files.isDirectory(overridesRoot)) {
                        throw new IOException("Modpack overrides path is not a directory: "
                                + overridesRoot);
                    }
                    Path instanceRoot = new File(instance.gameDir).toPath()
                            .toAbsolutePath().normalize();
                    Files.walkFileTree(overridesRoot, new FileVisitor<Path>() {
                        @Override
                        public FileVisitResult preVisitDirectory(
                                Path dir, BasicFileAttributes attrs) {
                            return FileVisitResult.CONTINUE;
                        }

                        @Override
                        public FileVisitResult visitFile(
                                Path file, BasicFileAttributes attrs) throws IOException {
                            Path relative = overridesRoot.relativize(file);
                            Path destination = instanceRoot.resolve(relative).normalize();
                            if(!destination.startsWith(instanceRoot)) {
                                throw new IOException(
                                        "Modpack override escaped the instance root: " + relative);
                            }
                            File newFile = destination.toFile();
                            if(newFile.getParentFile() != null
                                    && !newFile.getParentFile().isDirectory()
                                    && !newFile.getParentFile().mkdirs()) {
                                throw new IOException(
                                        "Could not create modpack override directory: "
                                                + newFile.getParentFile());
                            }

                            Files.copy(file, newFile.toPath(),
                                    StandardCopyOption.REPLACE_EXISTING);
                            return FileVisitResult.CONTINUE;
                        }

                        @Override
                        public FileVisitResult visitFileFailed(
                                Path file, IOException exc) throws IOException {
                            throw exc != null ? exc
                                    : new IOException("Could not visit modpack override: " + file);
                        }

                        @Override
                        public FileVisitResult postVisitDirectory(
                                Path dir, IOException exc) throws IOException {
                            if(exc != null) {
                                throw exc;
                            }
                            return FileVisitResult.CONTINUE;
                        }
                    });
                }
                // The base creation path invokes this callback before its one
                // and only seed, so these user-owned modpack entries are
                // downloaded in the same transaction.
            } catch(IOException e) {
                throw new RuntimeException(e);
            } finally {
                cleanupMrpackStaging(setupFile);
            }
            }, () -> cleanupMrpackStaging(setupFile));
        } catch(RuntimeException failure) {
            cleanupMrpackStaging(setupFile);
            Logger.getInstance().appendToLog(
                    "Modpack instance creation failed before scheduling: "
                            + failure.getMessage());
            return null;
        }
        return created;
    }

    private static void cleanupMrpackStaging(File setupFile) {
        try {
            if(setupFile != null && setupFile.exists()) {
                FileUtils.deleteDirectory(setupFile);
            }
        } catch(IOException cleanupFailure) {
            Logger.getInstance().appendToLog(
                    "Deferred stale modpack staging cleanup: " + cleanupFailure.getMessage());
        }
    }

    //creates a new instance of a minecraft version, install game + mod loader, stores non login related launch info to json
    public static MinecraftInstances.Instance create(
            Activity activity, MinecraftInstances instances, String instanceName,
            String gameDir, boolean useDefaultMods, String minecraftVersion,
            String modLoader, String imageURL,
            Consumer<MinecraftInstances.Instance> postInstall) {
        return create(activity, instances, instanceName, gameDir, useDefaultMods,
                minecraftVersion, modLoader, imageURL, postInstall, null);
    }

    private static MinecraftInstances.Instance create(
            Activity activity, MinecraftInstances instances, String instanceName,
            String gameDir, boolean useDefaultMods, String minecraftVersion,
            String modLoader, String imageURL,
            Consumer<MinecraftInstances.Instance> postInstall,
            Runnable completionCleanup) {
        String targetGameDir = Constants.USER_HOME + "/instances/"
                + instanceName.toLowerCase(Locale.ROOT).replaceAll(" ", "_");
        if(instances != null && instances.instances != null) {
            for (MinecraftInstances.Instance instance : instances.instances) {
                if(sameInstanceTarget(instance, instanceName, targetGameDir)) {
                    if(completionCleanup != null) {
                        completionCleanup.run();
                    }
                    Logger.getInstance().appendToLog("Instance " + instanceName + " already exists! Using original instance.");
                    return instance;
                }
            }
        }

        Logger.getInstance().appendToLog("Creating new instance: " + instanceName);

        MinecraftInstances.Instance instance = new MinecraftInstances.Instance();
        instance.instanceName = instanceName;
        instance.instanceImageURL = imageURL;
        instance.versionName = minecraftVersion;
        instance.gameDir = targetGameDir;
        instance.defaultMods = useDefaultMods;
        instance.instanceSetupFailed = Boolean.FALSE;
        instance.instanceSetupInProgress = Boolean.TRUE;
        if("26.2".equals(minecraftVersion) && activity != null
                && MinecraftInstances.Instance.PERSONAL_PACKAGE.equals(activity.getPackageName())) {
            instance.enableSeedOnlyModManagement();
        }

        File gameDirFile = new File(instance.gameDir);
        if(!gameDirFile.exists()) {
            gameDirFile.mkdirs();
        }

        VersionInfo modLoaderVersionInfo = null;
        switch (modLoader) {
            case "Fabric": {
                FabricMeta.FabricVersion fabricVersion = "26.2".equals(minecraftVersion)
                        ? FabricMeta.getVersion(FABRIC_LOADER_26_2)
                        : FabricMeta.getLatestVersion();
                assert fabricVersion != null;
                modLoaderVersionInfo = FabricMeta.getVersionInfo(fabricVersion, minecraftVersion);
                break;
            }
            case "Quilt": {
                QuiltMeta.QuiltVersion quiltVersion = QuiltMeta.getLatestVersion();
                assert quiltVersion != null;
                modLoaderVersionInfo = QuiltMeta.getVersionInfo(quiltVersion, minecraftVersion);
                break;
            }
            case "Forge":
            case "NeoForge": {
                break;
            }
        }

        VersionInfo minecraftVersionInfo = MinecraftMeta.getVersionInfo(minecraftVersion);
        instance.versionType = minecraftVersionInfo.type;
        instance.mainClass = modLoaderVersionInfo.mainClass;

        // Install minecraft
        VersionInfo finalModLoaderVersionInfo = modLoaderVersionInfo;

        final String creationKey = instanceCreationKey(instance.gameDir);
        synchronized(CREATION_REGISTRATION_LOCK) {
            if(instances.instances == null) {
                instances.instances = new MinecraftInstances.Instance[0];
            }
            for(MinecraftInstances.Instance existing : instances.instances) {
                if(sameInstanceTarget(existing, instanceName, targetGameDir)) {
                    if(completionCleanup != null) {
                        completionCleanup.run();
                    }
                    Logger.getInstance().appendToLog(
                            "Instance " + instanceName
                                    + " was registered by another creator; using it.");
                    return existing;
                }
            }

            if(!ACTIVE_INSTANCE_CREATIONS.add(creationKey)) {
                if(completionCleanup != null) {
                    completionCleanup.run();
                }
                Logger.getInstance().appendToLog(
                        "Another instance creation already owns this profile directory.");
                return null;
            }

            MinecraftInstances.Instance[] previousInstances = instances.instances;
            ArrayList<MinecraftInstances.Instance> instances1 =
                    Lists.newArrayList(previousInstances);
            instances1.add(instance);
            instances.instances = instances1.toArray(new MinecraftInstances.Instance[0]);
            // Publish the live creator before persisting the in-progress marker. A
            // concurrent load can observe the marker as soon as the atomic replace
            // completes, so registering afterward leaves a small false-recovery
            // window where a healthy creation is marked failed.
            boolean registrationPersisted;
            try {
                registrationPersisted = instance.persistMetadataAtomically(instances);
            } catch(RuntimeException persistenceFailure) {
                ACTIVE_INSTANCE_CREATIONS.remove(creationKey);
                instances.instances = previousInstances;
                if(completionCleanup != null) {
                    completionCleanup.run();
                }
                Logger.getInstance().appendToLog(
                        "Instance creation metadata threw before registration completed: "
                                + persistenceFailure.getMessage());
                return null;
            }
            if(!registrationPersisted) {
                ACTIVE_INSTANCE_CREATIONS.remove(creationKey);
                instances.instances = previousInstances;
                if(completionCleanup != null) {
                    completionCleanup.run();
                }
                Logger.getInstance().appendToLog(
                        "Instance creation could not record its in-progress state; creation aborted safely.");
                return null;
            }
        }

        CompletableFuture.supplyAsync(() ->
        {
            boolean baseInstallReady = true;
            try {
                CompletableFuture<String> clientClasspath = Installer.installClient(minecraftVersionInfo, gameDir);
                CompletableFuture<String> minecraftClasspath = Installer.installLibraries(minecraftVersionInfo, gameDir);
                CompletableFuture<String> modLoaderClasspath = Installer.installLibraries(finalModLoaderVersionInfo, gameDir);
                CompletableFuture<String> assetsFuture = Installer.installAssets(minecraftVersionInfo, gameDir);
                String lwjgl = UnityPlayerActivity.installLWJGL(activity);

                CompletableFuture<Void> installFuture = CompletableFuture.allOf(clientClasspath, minecraftClasspath, modLoaderClasspath, assetsFuture);
                installFuture.get();

                String clientPath = requireInstallPath("Minecraft client", clientClasspath.get());
                String minecraftLibraries = requireInstallPath(
                        "Minecraft libraries", minecraftClasspath.get());
                String modLoaderLibraries = requireInstallPath(
                        "mod-loader libraries", modLoaderClasspath.get());
                String lwjglPath = requireInstallPath("LWJGL", lwjgl);
                String assetsPath = requireInstallPath("Minecraft assets", assetsFuture.get());
                File installedClient = new File(clientPath);
                if(!installedClient.isFile()
                        || !pojlib.util.download.DownloadUtils.compareSHA1(
                                installedClient, minecraftVersionInfo.downloads.client.sha1)) {
                    throw new IOException("Minecraft client integrity check failed after install");
                }
                File installedIndex = new File(gameDir + "/assets/indexes/"
                        + minecraftVersionInfo.assets + ".json");
                if(!installedIndex.isFile()) {
                    throw new IOException("Minecraft asset index is missing after install");
                }

                instance.classpath = clientPath + File.pathSeparator
                        + minecraftLibraries + File.pathSeparator
                        + modLoaderLibraries + File.pathSeparator + lwjglPath;

                instance.assetsDir = assetsPath;
                Installer.moveLocalAssets(activity, instance);
            } catch(InterruptedException interrupted) {
                Thread.currentThread().interrupt();
                baseInstallReady = false;
                Logger.getInstance().appendToLog(
                        "Instance installation was interrupted; launch remains blocked.");
            } catch(IOException | ExecutionException failure) {
                baseInstallReady = false;
                Logger.getInstance().appendToLog(
                        "Instance installation failed; launch remains blocked: " + failure);
            } catch(RuntimeException failure) {
                baseInstallReady = false;
                Logger.getInstance().appendToLog(
                        "Instance installation failed unexpectedly; launch remains blocked: "
                                + failure);
            }
            if(!baseInstallReady) {
                instance.instanceSetupInProgress = Boolean.FALSE;
                instance.instanceSetupFailed = Boolean.TRUE;
                if(instance.usesSeedOnlyModManagement()) {
                    instance.managedModsSeeded = Boolean.FALSE;
                    instance.managedModsSeedRoot = null;
                }
                instance.persistMetadataAtomically(instances);
                DownloadManager.reset();
                return null;
            }
            instance.assetIndex = minecraftVersionInfo.assetIndex.id;

            boolean postInstallReady = true;
            if(postInstall != null) {
                try {
                    postInstall.accept(instance);
                } catch(RuntimeException failure) {
                    postInstallReady = false;
                    instance.instanceSetupFailed = Boolean.TRUE;
                    instance.managedModsSeeded = Boolean.FALSE;
                    instance.managedModsSeedRoot = null;
                    Logger.getInstance().appendToLog(
                            "Instance post-install failed; managed seed was not committed: " + failure);
                }
            }

            if(!postInstallReady) {
                instance.instanceSetupInProgress = Boolean.FALSE;
                instance.persistMetadataAtomically(instances);
                DownloadManager.reset();
                return null;
            }

            // Keep setupInProgress true through the entire network seed. Play
            // must not reset shared download state or enter a partially seeded
            // profile while this creator still owns the transaction.
            boolean managedModsReady = instance.isPersonalSeedOnlyProfile(activity)
                    ? instance.seedManagedMods(activity, instances)
                    : instance.updateMods(activity, instances);
            instance.instanceSetupInProgress = Boolean.FALSE;
            // A failed network seed is retryable from Play; base/post-install
            // failures above remain hard failures that require recreation.
            instance.instanceSetupFailed = Boolean.FALSE;
            boolean finalMetadataReady = instance.persistMetadataAtomically(instances);
            if(!finalMetadataReady) {
                // Prevent a same-process launch even though the durable marker
                // will also be recovered as interrupted on the next load.
                instance.instanceSetupFailed = Boolean.TRUE;
            }

            DownloadManager.reset();
            Logger.getInstance().appendToLog(managedModsReady && finalMetadataReady
                    ? "Finished Creating Instance!"
                    : "Instance files created, but the initial managed mod seed or its metadata is incomplete; Play will retry or fail closed safely.");
            return null;
        }).whenComplete((unused, failure) -> {
            try {
                if(failure != null) {
                    instance.instanceSetupFailed = Boolean.TRUE;
                    if(instance.usesSeedOnlyModManagement()) {
                        instance.managedModsSeeded = Boolean.FALSE;
                        instance.managedModsSeedRoot = null;
                    }
                    // Publish completion last; the runtime ACTIVE guard remains
                    // set until this durable failure transition has finished.
                    instance.instanceSetupInProgress = Boolean.FALSE;
                    instance.persistMetadataAtomically(instances);
                    Logger.getInstance().appendToLog(
                            "Instance creation stopped unexpectedly; launch remains blocked: "
                                    + failure);
                }
            } finally {
                ACTIVE_INSTANCE_CREATIONS.remove(creationKey);
                if(completionCleanup != null) {
                    completionCleanup.run();
                }
            }
        });

        return instance;
    }

    private static String requireInstallPath(String component, String path) throws IOException {
        if(path == null || path.trim().isEmpty()) {
            throw new IOException(component + " returned an empty installation path");
        }
        return path;
    }

    // Load an instance from json
    public static MinecraftInstances load(String gameDir) {
        MinecraftInstances instances;
        try {
            instances = GsonUtils.jsonFileToObject(gameDir + "/instances.json", MinecraftInstances.class);
        } catch (Exception e) {
            instances = new MinecraftInstances();
            instances.instances = new MinecraftInstances.Instance[0];
        }
        if(instances == null) {
            instances = new MinecraftInstances();
            instances.instances = new MinecraftInstances.Instance[0];
            GsonUtils.objectToJsonFile(gameDir + "/instances.json", instances);
        }

        boolean interruptedCreationFound = false;
        MinecraftInstances.Instance metadataWriter = null;
        if(instances.instances != null) {
            for(MinecraftInstances.Instance instance : instances.instances) {
                if(metadataWriter == null && instance != null) {
                    metadataWriter = instance;
                }
                if(instance != null && Boolean.TRUE.equals(instance.instanceSetupInProgress)
                        && !isInstanceCreationActive(instance)) {
                    instance.instanceSetupInProgress = Boolean.FALSE;
                    instance.instanceSetupFailed = Boolean.TRUE;
                    interruptedCreationFound = true;
                }
            }
        }
        if(interruptedCreationFound && metadataWriter != null) {
            metadataWriter.persistMetadataAtomically(instances);
            Logger.getInstance().appendToLog(
                    "Recovered an interrupted instance creation; recreate that profile before Play.");
        }

        return instances;
    }

    public static boolean addExtraProject(
            Activity activity, MinecraftInstances instances,
            MinecraftInstances.Instance instance, String name, String fileName,
            String version, String url, String type) {
        return addExtraProjects(activity, instances, instance,
                new String[] {name}, new String[] {fileName},
                new String[] {version}, new String[] {url}, new String[] {type});
    }

    public static boolean addExtraProjects(
            Activity activity, MinecraftInstances instances,
            MinecraftInstances.Instance instance, String[] names,
            String[] fileNames, String[] versions, String[] urls,
            String[] types) {
        if(activity == null || instances == null || instance == null) {
            return false;
        }
        int count = names == null ? -1 : names.length;
        if(count <= 0 || fileNames == null || versions == null || urls == null
                || types == null || fileNames.length != count || versions.length != count
                || urls.length != count || types.length != count) {
            return false;
        }
        ArrayList<ProjectInfo> requested = new ArrayList<>();
        for(int i = 0; i < count; ++i) {
            ProjectInfo info = new ProjectInfo();
            info.slug = names[i];
            info.fileName = fileNames[i];
            info.download_link = urls[i];
            info.version = versions[i];
            info.type = types[i];
            requested.add(info);
        }

        if(instance.isPersonalSeedOnlyProfile(activity)) {
            if(!instance.migrateExistingPersonalProfileToSeedOnly(activity, instances)
                    || !instance.preservesUserManagedMods(activity)) {
                return false;
            }
            return instance.installUserProjects(activity, instances, requested);
        }

        if(instance.extProjects == null) {
            instance.extProjects = new ProjectInfo[0];
        }

        ArrayList<ProjectInfo> mods = Lists.newArrayList(instance.extProjects);
        mods.addAll(requested);
        instance.extProjects = mods.toArray(new ProjectInfo[0]);
        for(ProjectInfo info : requested) {
            instance.enableManagedMod(info.slug);
        }

        return instance.persistMetadataAtomically(instances);
    }

    public static boolean hasExtraProject(MinecraftInstances.Instance instance, String name) {
        if(instance == null || instance.extProjects == null || name == null) {
            return false;
        }
        for(ProjectInfo info : instance.extProjects) {
            if(info != null && info.slug != null && info.slug.equalsIgnoreCase(name)) {
                return true;
            }
        }

        return false;
    }

    public static boolean hasInstalledExtraProject(
            MinecraftInstances.Instance instance, String name) {
        return instance != null && instance.hasInstalledUserProject(name);
    }

    private static boolean isCoreMod(MinecraftInstances.Instance instance, ProjectInfo oldInfo) {
        // Check if its a coremod
        ModsJson oldMods = instance.parseModsJson(Constants.USER_HOME + "/mods.json");
        if(oldMods != null) {
            Optional<ModsJson.Version> ver = Arrays.stream(oldMods.versions).filter((v) -> v.name.equals(instance.versionName)).findFirst();
            if(ver.isPresent()) {
                ModsJson.Version version = ver.get();
                Optional<ProjectInfo> info = Arrays.stream(version.coreMods).filter((mod) -> mod.slug.equals(oldInfo.slug)).findFirst();
                return info.isPresent();
            }
        }

        return false;
    }

    private static boolean isManagedDefaultMod(MinecraftInstances.Instance instance, ProjectInfo oldInfo) {
        ModsJson oldMods = instance.parseModsJson(Constants.USER_HOME + "/mods.json");
        if(oldMods == null || oldMods.versions == null) {
            return false;
        }
        Optional<ModsJson.Version> version = Arrays.stream(oldMods.versions)
                .filter(v -> v != null && instance.versionName.equals(v.name))
                .findFirst();
        if(!version.isPresent() || version.get().defaultMods == null) {
            return false;
        }
        return Arrays.stream(version.get().defaultMods)
                .anyMatch(mod -> mod != null && mod.slug.equalsIgnoreCase(oldInfo.slug));
    }

    public static boolean removeExtraProject(
            Activity activity, MinecraftInstances instances,
            MinecraftInstances.Instance instance, String name) {
        if(activity == null || instances == null || instance == null) {
            return false;
        }
        ProjectInfo oldInfo = Arrays.stream(instance.extProjects).filter(info -> info.slug.equalsIgnoreCase(name)).findFirst().orElse(null);

        if(oldInfo != null) {
            boolean managedDefault = isManagedDefaultMod(instance, oldInfo);
            if(instance.isPersonalSeedOnlyProfile(activity)) {
                if(!instance.migrateExistingPersonalProfileToSeedOnly(activity, instances)
                        || !instance.preservesUserManagedMods(activity)) {
                    return false;
                }
                return instance.removeUserProject(instances, oldInfo, managedDefault);
            }
            boolean isMod = oldInfo.type.equals("mod");

            // Personal seed-only removal returned above. Every other package,
            // including Lab with copied/spoofed policy metadata, keeps the
            // longstanding core-mod deletion guard.
            if(isCoreMod(instance, oldInfo)) {
                return false;
            }

            // Delete the mod
            try {
                Files.deleteIfExists(instance.resolveExistingProjectArtifact(oldInfo).toPath());
            } catch(IOException failure) {
                return false;
            }

            ArrayList<ProjectInfo> mods = Lists.newArrayList(instance.extProjects);
            mods.remove(oldInfo);
            instance.extProjects = mods.toArray(mods.toArray(new ProjectInfo[0]));
            if(managedDefault) {
                instance.disableManagedMod(oldInfo.slug);
            }
            GsonUtils.objectToJsonFile(Constants.USER_HOME + "/instances.json", instances);
            return true;
        }

        return false;
    }

    // Return true if instance was deleted
    public static boolean delete(MinecraftInstances instances, MinecraftInstances.Instance instance) throws IOException {
        File instanceDir = new File(instance.gameDir);
        Files.walkFileTree(instanceDir.toPath(), new FileVisitor<Path>() {
            @Override
            public FileVisitResult preVisitDirectory(Path dir, BasicFileAttributes attrs) throws IOException {
                return FileVisitResult.CONTINUE;
            }

            @Override
            public FileVisitResult visitFile(Path file, BasicFileAttributes attrs) throws IOException {
                Files.delete(file);
                return FileVisitResult.CONTINUE;
            }

            @Override
            public FileVisitResult visitFileFailed(Path file, IOException exc) throws IOException {
                return FileVisitResult.CONTINUE;
            }

            @Override
            public FileVisitResult postVisitDirectory(Path dir, IOException exc) throws IOException {
                Files.delete(dir);
                return FileVisitResult.CONTINUE;
            }
        });

        ArrayList<MinecraftInstances.Instance> instances1 = Lists.newArrayList(instances.instances);
        instances1.remove(instance);
        instances.instances = instances1.toArray(new MinecraftInstances.Instance[0]);
        GsonUtils.objectToJsonFile(Constants.USER_HOME + "/instances.json", instances);

        return instanceDir.delete();
    }

    public static boolean launchInstance(Activity activity, MinecraftAccount account, MinecraftInstances.Instance instance) {
        return launchInstance(activity, account, instance, false);
    }

    public static boolean launchInstance(Activity activity, MinecraftAccount account,
                                         MinecraftInstances.Instance instance,
                                         boolean quickPlaySingleplayer) {
        try {
            API.currentInstance = instance;
            JREUtils.redirectAndPrintJRELog();
            VLoader.setAndroidInitInfo(activity);
            List<String> launchArgs = instance.generateLaunchArgs(account);
            int classpathIndex = launchArgs.indexOf("-cp");
            if(classpathIndex < 0) {
                throw new IllegalStateException("Minecraft classpath argument is missing");
            }
            launchArgs.add(classpathIndex, OPENXR_COPY_BATCH_PROPERTY +
                    VivecraftCoreCanaryGate.takeOpenXrCopyBatchMode(activity, instance));
            if(quickPlaySingleplayer) {
                launchArgs.add("--quickPlaySingleplayer");
                launchArgs.add("FPS-Stress-Test");
            }
            JREUtils.launchJavaVM(activity, launchArgs, instance);
            return true;
        } catch (Throwable e) {
            Logger.getInstance().appendToLog(
                    "QC_JVM_LAUNCH_DISPATCH_REJECTED type=" + e.getClass().getSimpleName());
            e.printStackTrace();
            return false;
        }
    }
}
