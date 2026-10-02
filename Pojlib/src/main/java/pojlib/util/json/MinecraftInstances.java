package pojlib.util.json;

import android.content.Context;

import com.google.gson.JsonObject;
import com.google.gson.JsonPrimitive;

import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.FileInputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.InputStreamReader;
import java.nio.file.AtomicMoveNotSupportedException;
import java.nio.file.Files;
import java.nio.file.StandardCopyOption;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.HashSet;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Locale;
import java.util.Set;
import java.util.UUID;

import pojlib.account.MinecraftAccount;
import pojlib.API;
import pojlib.APIHandler;
import pojlib.InstanceHandler;
import pojlib.util.Constants;
import pojlib.util.FileUtil;
import pojlib.util.download.DownloadManager;
import pojlib.util.download.DownloadUtils;
import pojlib.util.GsonUtils;
import pojlib.util.Logger;

public class MinecraftInstances {
    private static final String QUESTCRAFT_VULKAN_INSTANCE_EXTENSIONS =
            "VK_KHR_surface VK_KHR_android_surface VK_KHR_external_memory_capabilities " +
            "VK_KHR_get_physical_device_properties2 VK_KHR_surface_protected_capabilities";
    private static final String QUESTCRAFT_VULKAN_DEVICE_EXTENSIONS =
            "VK_KHR_swapchain VK_KHR_external_memory VK_KHR_get_memory_requirements2 " +
            "VK_ANDROID_external_memory_android_hardware_buffer VK_EXT_queue_family_foreign " +
            "VK_KHR_external_memory_fd VK_KHR_sampler_ycbcr_conversion";

    public Instance[] instances;

    public Instance load(String name) {
        for(Instance instance : instances) {
            if(instance.instanceName.equals(name)) {
                return instance;
            }
        }

        return null;
    }

    public Instance[] toArray() {
        if(instances == null) {
            return new Instance[0];
        }
        return instances;
    }

    public static void CheckVivecraftConfig(MinecraftInstances.Instance instance) {
        File config = new File(instance.gameDir + "/config/vivecraft-client-config.json");
        if (!config.exists()) {
            Logger.getInstance().appendToLog("Vivecraft config not found, skipping modification");
            return;
        }

        try {
            JsonObject obj = GsonUtils.jsonFileToObject(config.getAbsolutePath(), JsonObject.class);
            if (obj == null) {
                Logger.getInstance().appendToLog("Vivecraft config could not be parsed, skipping modification");
                return;
            }

            // Only enforce standalone Quest platform requirements. User-facing
            // preferences such as seated mode, update prompts, rendering and
            // performance settings remain owned by the per-instance config.
            boolean changed = false;
            changed |= setStringProperty(obj, "stereoProviderPluginID", "OPENXR");
            changed |= setStringProperty(obj, "vrEnabled", "true");
            changed |= setStringProperty(obj, "vrToggleButtonEnabled", "false");
            changed |= setStringProperty(obj, "vrHotswitchingEnabled", "false");

            // Vivecraft cannot add required Vulkan extensions after the device is created.
            // Seed Quest's known requirements to avoid an intentional first-launch restart,
            // while preserving any non-empty list already detected by the runtime.
            if (isMissingOrBlank(obj, "requiredVulkanInstanceExtensions")) {
                obj.addProperty("requiredVulkanInstanceExtensions", QUESTCRAFT_VULKAN_INSTANCE_EXTENSIONS);
                changed = true;
            }
            if (isMissingOrBlank(obj, "requiredVulkanDeviceExtensions")) {
                obj.addProperty("requiredVulkanDeviceExtensions", QUESTCRAFT_VULKAN_DEVICE_EXTENSIONS);
                changed = true;
            }

            if (changed) {
                Logger.getInstance().appendToLog("Applying Quest OpenXR/Vulkan requirements to Vivecraft config");
                GsonUtils.objectToJsonFile(config.getAbsolutePath(), obj);
            }
        } catch (Exception e) {
            Logger.getInstance().appendToLog("Failed to modify Vivecraft config");
            e.printStackTrace();
        }
    }

    private static boolean setStringProperty(JsonObject object, String property, String value) {
        JsonPrimitive replacement = new JsonPrimitive(value);
        if (object.has(property) && replacement.equals(object.get(property))) {
            return false;
        }
        object.add(property, replacement);
        return true;
    }

    private static boolean isMissingOrBlank(JsonObject object, String property) {
        if (!object.has(property) || object.get(property).isJsonNull()) {
            return true;
        }
        return object.get(property).isJsonPrimitive()
                && object.get(property).getAsString().trim().isEmpty();
    }

    public static class Instance {
        public static final String MOD_MANAGEMENT_SEED_ONLY = "seed-only";
        public static final String PERSONAL_PACKAGE = "com.qcxr.qcxr.dev262";
        private static final Object MOD_MANAGEMENT_LOCK = new Object();

        public String instanceName;
        public String instanceImageURL;
        public String versionName;
        public String versionType;
        public String classpath;
        public String gameDir;
        public String assetIndex;
        public String assetsDir;
        public String mainClass;
        public String extraNatives;
        public ProjectInfo[] extProjects;
        public String[] disabledMods;
        public boolean defaultMods;
        /**
         * Personal Quest profiles install the bundled stack once and then
         * leave every JAR under user control.  A nullable Boolean is used so
         * old profiles can be distinguished from a newly created profile
         * whose first seed has not completed yet.
         */
        public String modManagementPolicy;
        public Boolean managedModsSeeded;
        /** Canonical game directory that completed the one-time managed seed. */
        public String managedModsSeedRoot;
        /** True only when base game/modpack creation failed before a safe seed. */
        public Boolean instanceSetupFailed;
        /** Persistent guard so Play cannot race or resume an interrupted creator. */
        public volatile Boolean instanceSetupInProgress;

        public void enableSeedOnlyModManagement() {
            modManagementPolicy = MOD_MANAGEMENT_SEED_ONLY;
            if(managedModsSeeded == null) {
                managedModsSeeded = Boolean.FALSE;
            }
        }

        public boolean usesSeedOnlyModManagement() {
            return MOD_MANAGEMENT_SEED_ONLY.equalsIgnoreCase(modManagementPolicy);
        }

        public boolean isPersonalSeedOnlyProfile(String packageName) {
            return PERSONAL_PACKAGE.equals(packageName) && requiresQuestVulkanBackend();
        }

        public boolean isPersonalSeedOnlyProfile(Context ctx) {
            return ctx != null && isPersonalSeedOnlyProfile(ctx.getPackageName());
        }

        /**
         * Returns true only after this exact Personal profile directory has
         * completed its one-time seed. Package/version checks prevent a copied
         * instances.json from disabling the strict Lab reconciliation policy.
         */
        public boolean preservesUserManagedMods(Context ctx) {
            return ctx != null && preservesUserManagedMods(ctx.getPackageName());
        }

        boolean preservesUserManagedMods(String packageName) {
            if(!isPersonalSeedOnlyProfile(packageName)
                    || !hasCompletedSeedOnlyOwnership()) {
                return false;
            }
            return seedRootMatchesGameDirectory();
        }

        private boolean hasCompletedSeedOnlyOwnership() {
            return usesSeedOnlyModManagement()
                    && Boolean.TRUE.equals(managedModsSeeded)
                    && managedModsSeedRoot != null && gameDir != null;
        }

        private boolean seedRootMatchesGameDirectory() {
            try {
                return new File(gameDir).getCanonicalPath().equals(managedModsSeedRoot);
            } catch(IOException ignored) {
                return false;
            }
        }

        /** The only state that may perform an automatic first seed on Play. */
        public boolean needsInitialManagedSeed(Context ctx) {
            return ctx != null && needsInitialManagedSeed(ctx.getPackageName());
        }

        boolean needsInitialManagedSeed(String packageName) {
            return isPersonalSeedOnlyProfile(packageName)
                    && usesSeedOnlyModManagement()
                    && Boolean.FALSE.equals(managedModsSeeded)
                    && managedModsSeedRoot == null
                    && Boolean.FALSE.equals(instanceSetupFailed)
                    && Boolean.FALSE.equals(instanceSetupInProgress);
        }

        /**
         * Existing Personal profiles predate the policy fields.  Their files
         * are already user data, so migration claims ownership without one
         * last destructive reconciliation.  Lab and all other packages keep
         * their strict managed/canary behavior.
         */
        public boolean migrateExistingPersonalProfileToSeedOnly(
                Context ctx, MinecraftInstances instances) {
            synchronized(MOD_MANAGEMENT_LOCK) {
                return migrateExistingPersonalProfileToSeedOnlyLocked(ctx, instances);
            }
        }

        private boolean migrateExistingPersonalProfileToSeedOnlyLocked(
                Context ctx, MinecraftInstances instances) {
            if(ctx == null || instances == null || !PERSONAL_PACKAGE.equals(ctx.getPackageName())
                    || !requiresQuestVulkanBackend() || modManagementPolicy != null) {
                return true;
            }
            String previousPolicy = modManagementPolicy;
            Boolean previousSeeded = managedModsSeeded;
            String previousSeedRoot = managedModsSeedRoot;
            modManagementPolicy = MOD_MANAGEMENT_SEED_ONLY;
            managedModsSeeded = Boolean.TRUE;
            try {
                managedModsSeedRoot = new File(gameDir).getCanonicalPath();
                persistInstancesAtomically(instances);
                Logger.getInstance().appendToLog(
                        "Migrated existing Personal profile to seed-only mod ownership.");
                return true;
            } catch(IOException failure) {
                modManagementPolicy = previousPolicy;
                managedModsSeeded = previousSeeded;
                managedModsSeedRoot = previousSeedRoot;
                Logger.getInstance().appendToLog(
                        "Seed-only mod policy migration failed; launch aborted safely.");
                return false;
            }
        }

        public boolean persistMetadataAtomically(MinecraftInstances instances) {
            try {
                persistInstancesAtomically(instances);
                return true;
            } catch(IOException failure) {
                Logger.getInstance().appendToLog(
                        "Could not persist instance metadata atomically: " + failure.getMessage());
                return false;
            }
        }

        public List<String> generateLaunchArgs(MinecraftAccount account) {
            String[] mcArgs = {"--username", account.username, "--version", versionName, "--gameDir", gameDir,
                    "--assetsDir", assetsDir, "--assetIndex", assetIndex, "--uuid", account.uuid.replace("-", ""),
                    "--accessToken", account.accessToken, "--userType", account.userType, "--versionType", "release"};

            List<String> allArgs = new ArrayList<>();
            allArgs.add("-cp");
            allArgs.add(classpath);
            allArgs.add(mainClass);
            allArgs.addAll(Arrays.asList(mcArgs));
            if (requiresQuestVulkanBackend()) {
                allArgs.add("--graphicsBackend");
                allArgs.add("vulkan");
            }
            if (account.isDemoMode) {
                allArgs.add("--demo");
            }

            return allArgs;
        }

        /**
         * The selected launcher object can outlive one instance-list refresh.
         * Keep the mandatory Quest 26.2 Vulkan contract keyed by every stable
         * instance identity instead of trusting versionName alone.
         */
        private boolean requiresQuestVulkanBackend() {
            if ("26.2".equals(versionName) || "26.2".equals(instanceName)) {
                return true;
            }
            return gameDir != null && "26.2".equals(new File(gameDir).getName());
        }

        public ProjectInfo[] toArray() {
            if(extProjects == null) {
                return new ProjectInfo[0];
            }
            return extProjects;
        }

        public void disableManagedMod(String slug) {
            if(slug == null || slug.trim().isEmpty()) {
                return;
            }
            LinkedHashSet<String> disabled = normalizedDisabledMods();
            disabled.add(slug.trim());
            disabledMods = disabled.toArray(new String[0]);
        }

        public void enableManagedMod(String slug) {
            if(slug == null || disabledMods == null) {
                return;
            }
            LinkedHashSet<String> enabled = new LinkedHashSet<>();
            for(String disabled : disabledMods) {
                if(disabled != null && !disabled.equalsIgnoreCase(slug)) {
                    enabled.add(disabled);
                }
            }
            disabledMods = enabled.toArray(new String[0]);
        }

        private boolean isManagedModDisabled(String slug) {
            if(slug == null || disabledMods == null) {
                return false;
            }
            for(String disabled : disabledMods) {
                if(disabled != null && disabled.equalsIgnoreCase(slug)) {
                    return true;
                }
            }
            return false;
        }

        private LinkedHashSet<String> normalizedDisabledMods() {
            LinkedHashSet<String> normalized = new LinkedHashSet<>();
            if(disabledMods == null) {
                return normalized;
            }
            for(String disabled : disabledMods) {
                if(disabled == null) {
                    continue;
                }
                String trimmed = disabled.trim();
                boolean duplicate = false;
                for(String existing : normalized) {
                    if(existing.equalsIgnoreCase(trimmed)) {
                        duplicate = true;
                        break;
                    }
                }
                if(!trimmed.isEmpty() && !duplicate) {
                    normalized.add(trimmed);
                }
            }
            return normalized;
        }

        public ModsJson parseModsJson(String jsonPath) {
            return GsonUtils.jsonFileToObject(jsonPath, ModsJson.class);
        }

        private ModsJson downloadCurrentModsJson(Context ctx, String userHome) throws Exception {
            File mods = new File(userHome + "/new_mods.json");
            String bundledManifest = API.developerMods ? "devmods.json" : "mods.json";
            if(APIHandler.copyBundledManifest(ctx, bundledManifest, mods)) {
                Logger.getInstance().appendToLog("Using bundled " + bundledManifest + ".");
                return parseModsJson(mods.getAbsolutePath());
            }

            if(API.developerMods) {
                DownloadUtils.downloadFile(InstanceHandler.DEV_MODS, mods);
            } else {
                DownloadUtils.downloadFile(InstanceHandler.MODS, mods);
            }

            return parseModsJson(mods.getAbsolutePath());
        }

        private void removeModByType(List<ProjectInfo> oldMods, List<ProjectInfo> newMods) {
            ArrayList<ProjectInfo> removedMods = new ArrayList<>();

            for(ProjectInfo oldMod : oldMods) {
                boolean exists = false;
                for(ProjectInfo newMod : newMods) {
                    if(!oldMod.slug.equals(newMod.slug)) {
                        continue;
                    }
                    exists = true;
                    break;
                }

                if(!exists) {
                    removedMods.add(oldMod);
                }
            }

            ArrayList<ProjectInfo> newExtProjects = new ArrayList<>();
            for(ProjectInfo extProject : extProjects) {
                boolean remove = false;
                for(ProjectInfo removedMod : removedMods) {
                    if (extProject.slug.equals(removedMod.slug)) {
                        remove = true;
                        break;
                    }
                }
                if(!remove) {
                    newExtProjects.add(extProject);
                } else {
                    boolean legacyMod = extProject.fileName == null;
                    File mod = new File(
                            gameDir + (extProject.type.equals("mod") ? "/mods" : "/resourcepacks"),
                            (legacyMod ? extProject.slug : extProject.fileName) + (extProject.type.equals("resourcepack") ? ".zip" : ".jar")
                    );
                    if(mod.exists()) {
                        mod.delete();
                    }
                }
            }
            extProjects = newExtProjects.toArray(new ProjectInfo[0]);
        }

        private void removeOldMods(ModsJson oldMods, ModsJson newMods) {
            for(ModsJson.Version oldVersion : oldMods.versions) {
                if(!versionName.equals(oldVersion.name)) {
                    continue;
                }

                for(ModsJson.Version newVersion : newMods.versions) {
                    if(!versionName.equals(newVersion.name)) {
                        continue;
                    }

                    ArrayList<ProjectInfo> mergedOldMods = new ArrayList<>();
                    mergedOldMods.addAll(Arrays.asList(oldVersion.coreMods));
                    mergedOldMods.addAll(Arrays.asList(oldVersion.defaultMods));

                    ArrayList<ProjectInfo> mergedNewMods = new ArrayList<>();
                    mergedNewMods.addAll(Arrays.asList(newVersion.coreMods));
                    mergedNewMods.addAll(Arrays.asList(newVersion.defaultMods));

                    if(defaultMods) {
                        removeModByType(mergedOldMods, mergedNewMods);
                    } else {
                        removeModByType(Arrays.asList(oldVersion.coreMods), Arrays.asList(newVersion.coreMods));
                    }
                    break;
                }
            }
        }

        private void installProject(Context ctx, ProjectInfo project, File destination, boolean unmanagedDownload) throws IOException {
            File parent = destination.getParentFile();
            if(parent != null) {
                parent.mkdirs();
            }
            File staged = new File(destination.getAbsolutePath() + ".questcraft-download");
            Files.deleteIfExists(staged.toPath());
            try {
                if(project.download_link.startsWith("asset://")) {
                    Files.write(staged.toPath(), FileUtil.loadFromAssetToByte(
                            ctx, project.download_link.substring("asset://".length())));
                } else if(unmanagedDownload) {
                    DownloadUtils.downloadFile(project.download_link, staged, 0);
                } else {
                    DownloadUtils.downloadFile(project.download_link, staged);
                }

                if(!matchesExpectedHash(project, staged)) {
                    throw new IOException("SHA-256 mismatch for managed project " + project.slug);
                }
                try {
                    Files.move(staged.toPath(), destination.toPath(),
                            StandardCopyOption.ATOMIC_MOVE, StandardCopyOption.REPLACE_EXISTING);
                } catch(AtomicMoveNotSupportedException ignored) {
                    Files.move(staged.toPath(), destination.toPath(), StandardCopyOption.REPLACE_EXISTING);
                }
            } finally {
                try {
                    Files.deleteIfExists(staged.toPath());
                } catch(IOException cleanupFailure) {
                    Logger.getInstance().appendToLog(
                            "Deferred stale project download cleanup: "
                                    + cleanupFailure.getMessage());
                }
            }
        }

        private boolean matchesExpectedHash(ProjectInfo project, File file) throws IOException {
            if(project.sha256 == null || project.sha256.trim().isEmpty()) {
                return true;
            }
            String expected = project.sha256.trim();
            if(!expected.matches("(?i)^[0-9a-f]{64}$")) {
                throw new IOException("Invalid SHA-256 in managed manifest for " + project.slug);
            }
            return expected.equalsIgnoreCase(sha256(file));
        }

        private String sha256(File file) throws IOException {
            try(FileInputStream input = new FileInputStream(file)) {
                MessageDigest digest = MessageDigest.getInstance("SHA-256");
                byte[] buffer = new byte[64 * 1024];
                int read;
                while((read = input.read(buffer)) != -1) {
                    digest.update(buffer, 0, read);
                }
                StringBuilder value = new StringBuilder(64);
                for(byte b : digest.digest()) {
                    value.append(String.format(Locale.ROOT, "%02x", b & 0xff));
                }
                return value.toString();
            } catch(NoSuchAlgorithmException e) {
                throw new IllegalStateException("SHA-256 is unavailable", e);
            }
        }

        public File resolveProjectArtifact(ProjectInfo project) throws IOException {
            if(project == null || gameDir == null || project.slug == null) {
                throw new IOException("Project metadata is incomplete");
            }
            boolean resourcePack = "resourcepack".equals(project.type);
            if(!resourcePack && !"mod".equals(project.type)) {
                throw new IOException("Unsupported project type: " + project.type);
            }
            String extension = resourcePack ? ".zip" : ".jar";
            String name = project.fileName == null || project.fileName.trim().isEmpty()
                    ? project.slug : project.fileName.trim();
            if(name.contains("/") || name.contains("\\") || ".".equals(name)
                    || "..".equals(name)) {
                throw new IOException("Unsafe project filename");
            }
            if(!name.toLowerCase(Locale.ROOT).endsWith(extension)) {
                name += extension;
            }
            File directory = new File(gameDir, resourcePack ? "resourcepacks" : "mods");
            File artifact = new File(directory, name);
            if(!directory.getCanonicalPath().equals(artifact.getCanonicalFile().getParent())) {
                throw new IOException("Project artifact escaped its profile directory");
            }
            return artifact;
        }

        /** Finds artifacts produced by both the corrected and legacy filename rules. */
        public File resolveExistingProjectArtifact(ProjectInfo project) throws IOException {
            File canonical = resolveProjectArtifact(project);
            if(project.fileName == null) {
                return canonical;
            }
            String extension = "resourcepack".equals(project.type) ? ".zip" : ".jar";
            if(!project.fileName.toLowerCase(Locale.ROOT).endsWith(extension)) {
                return canonical;
            }
            File legacyDoubleExtension = new File(
                    canonical.getParentFile(), canonical.getName() + extension);
            if(canonical.isFile() && legacyDoubleExtension.isFile()) {
                throw new IOException(
                        "Both canonical and legacy project artifacts exist for " + project.slug);
            }
            return legacyDoubleExtension.isFile() ? legacyDoubleExtension : canonical;
        }

        private static final class PendingUserInstall {
            ProjectInfo project;
            ProjectInfo ownedProject;
            File destination;
            File staged;
            File backup;
            boolean originalMoved;
            boolean installed;
        }

        /** Installs one user-selected project immediately for a seed-only profile. */
        public boolean installUserProject(
                Context ctx, MinecraftInstances instances, ProjectInfo project) {
            return installUserProjects(ctx, instances, Arrays.asList(project));
        }

        /** Returns true only when one unambiguous metadata entry has a real artifact. */
        public boolean hasInstalledUserProject(String slug) {
            synchronized(MOD_MANAGEMENT_LOCK) {
                if(slug == null || extProjects == null) {
                    return false;
                }
                ProjectInfo match = null;
                for(ProjectInfo existing : extProjects) {
                    if(existing != null && existing.slug != null
                            && existing.slug.equalsIgnoreCase(slug)) {
                        if(match != null) {
                            return false;
                        }
                        match = existing;
                    }
                }
                if(match == null) {
                    return false;
                }
                try {
                    return resolveExistingProjectArtifact(match).isFile();
                } catch(IOException unsafeOrAmbiguous) {
                    return false;
                }
            }
        }

        /**
         * Installs a requested project and all resolved required dependencies
         * as one filesystem/metadata transaction.
         */
        public boolean installUserProjects(
                Context ctx, MinecraftInstances instances, List<ProjectInfo> projects) {
            synchronized(MOD_MANAGEMENT_LOCK) {
                if(!preservesUserManagedMods(ctx) || instances == null
                        || projects == null || projects.isEmpty()) {
                    return false;
                }
                ProjectInfo[] previousProjects = extProjects == null
                        ? new ProjectInfo[0] : extProjects;
                String[] previousDisabled = disabledMods == null
                        ? null : disabledMods.clone();
                ArrayList<PendingUserInstall> pending = new ArrayList<>();
                try {
                    Set<String> batchSlugs = new HashSet<>();
                    Set<String> batchDestinations = new HashSet<>();
                    for(ProjectInfo project : projects) {
                        if(project == null || project.slug == null
                                || project.slug.trim().isEmpty()
                                || project.download_link == null
                                || !project.download_link.startsWith("https://")) {
                            throw new IOException("User project metadata is incomplete");
                        }
                        String normalizedSlug = project.slug.toLowerCase(Locale.ROOT);
                        if(!batchSlugs.add(normalizedSlug)) {
                            throw new IOException(
                                    "Duplicate project in install transaction: " + project.slug);
                        }

                        ProjectInfo owned = null;
                        for(ProjectInfo existing : previousProjects) {
                            if(existing != null && existing.slug != null
                                    && existing.slug.equalsIgnoreCase(project.slug)) {
                                if(owned != null) {
                                    throw new IOException(
                                            "Ambiguous existing project metadata: " + project.slug);
                                }
                                owned = existing;
                            }
                        }
                        if(owned != null) {
                            if(owned.type == null || project.type == null
                                    || !owned.type.equals(project.type)) {
                                throw new IOException(
                                        "A project update cannot change artifact type: "
                                                + project.slug);
                            }
                            // Same-slug updates keep the established path; no
                            // second mod-id copy is left behind.
                            project.fileName = owned.fileName;
                        }

                        File destination = owned == null
                                ? resolveProjectArtifact(project)
                                : resolveExistingProjectArtifact(owned);
                        String destinationPath = destination.getCanonicalPath();
                        if(!batchDestinations.add(destinationPath)) {
                            throw new IOException(
                                    "Multiple projects resolve to " + destination.getName());
                        }
                        for(ProjectInfo existing : previousProjects) {
                            if(existing == null || existing.slug == null
                                    || existing.slug.equalsIgnoreCase(project.slug)) {
                                continue;
                            }
                            if(resolveExistingProjectArtifact(existing).getCanonicalPath()
                                    .equals(destinationPath)) {
                                throw new IOException(
                                        "Project filename is already owned by " + existing.slug);
                            }
                        }
                        if(owned == null && destination.exists()) {
                            throw new IOException(
                                    "Project filename collides with an untracked user file: "
                                            + destination.getName());
                        }

                        File parent = destination.getParentFile();
                        if(parent == null || (!parent.isDirectory() && !parent.mkdirs())) {
                            throw new IOException("Could not create project directory");
                        }
                        PendingUserInstall item = new PendingUserInstall();
                        item.project = project;
                        item.ownedProject = owned;
                        item.destination = destination;
                        item.staged = new File(parent, "." + destination.getName()
                                + ".questcraft-user-stage-" + UUID.randomUUID());
                        pending.add(item);
                        installProject(ctx, project, item.staged, true);
                    }

                    // Every download succeeded before the first live JAR moves.
                    for(PendingUserInstall item : pending) {
                        File destination = item.destination;
                        // Close the download-time TOCTOU window: a new user file
                        // that appeared after validation is never treated as an
                        // update target and silently replaced.
                        if(item.ownedProject == null && destination.exists()) {
                            throw new IOException(
                                    "Project filename became occupied during download: "
                                            + destination.getName());
                        }
                        if(destination.isFile()) {
                            item.backup = new File(destination.getParentFile(),
                                    destination.getName() + ".questcraft-user-backup-"
                                            + UUID.randomUUID());
                            try {
                                Files.move(destination.toPath(), item.backup.toPath(),
                                        StandardCopyOption.ATOMIC_MOVE);
                            } catch(AtomicMoveNotSupportedException ignored) {
                                Files.move(destination.toPath(), item.backup.toPath());
                            }
                            item.originalMoved = true;
                        }
                        try {
                            Files.move(item.staged.toPath(), destination.toPath(),
                                    StandardCopyOption.ATOMIC_MOVE);
                        } catch(AtomicMoveNotSupportedException ignored) {
                            Files.move(item.staged.toPath(), destination.toPath());
                        }
                        item.installed = true;
                    }

                    ArrayList<ProjectInfo> updated = new ArrayList<>();
                    for(ProjectInfo existing : previousProjects) {
                        if(existing == null || existing.slug == null
                                || !batchSlugs.contains(
                                        existing.slug.toLowerCase(Locale.ROOT))) {
                            updated.add(existing);
                        }
                    }
                    for(PendingUserInstall item : pending) {
                        updated.add(item.project);
                        enableManagedMod(item.project.slug);
                    }
                    extProjects = updated.toArray(new ProjectInfo[0]);
                    persistInstancesAtomically(instances);

                    for(PendingUserInstall item : pending) {
                        try {
                            if(item.backup != null) {
                                Files.deleteIfExists(item.backup.toPath());
                            }
                        } catch(IOException cleanupFailure) {
                            Logger.getInstance().appendToLog(
                                    "Installed user project; stale backup cleanup was deferred: "
                                            + cleanupFailure.getMessage());
                        }
                    }
                    return true;
                } catch(Exception failure) {
                    extProjects = previousProjects;
                    disabledMods = previousDisabled;
                    for(int i = pending.size() - 1; i >= 0; --i) {
                        PendingUserInstall item = pending.get(i);
                        try {
                            if(item.installed) {
                                Files.deleteIfExists(item.destination.toPath());
                            }
                            if(item.originalMoved && item.backup != null
                                    && item.backup.isFile()
                                    && !item.destination.exists()) {
                                try {
                                    Files.move(item.backup.toPath(), item.destination.toPath(),
                                            StandardCopyOption.ATOMIC_MOVE);
                                } catch(AtomicMoveNotSupportedException ignored) {
                                    Files.move(item.backup.toPath(), item.destination.toPath());
                                }
                            }
                        } catch(IOException rollbackFailure) {
                            Logger.getInstance().appendToLog(
                                    "User project rollback failed for " + item.project.slug
                                            + ": " + rollbackFailure.getMessage());
                        } finally {
                            try {
                                Files.deleteIfExists(item.staged.toPath());
                            } catch(IOException cleanupFailure) {
                                Logger.getInstance().appendToLog(
                                        "Deferred user project staging cleanup: "
                                                + cleanupFailure.getMessage());
                            }
                        }
                    }
                    Logger.getInstance().appendToLog(
                            "Atomic user project installation failed: " + failure.getMessage());
                    return false;
                } finally {
                    for(PendingUserInstall item : pending) {
                        try {
                            Files.deleteIfExists(item.staged.toPath());
                        } catch(IOException cleanupFailure) {
                            Logger.getInstance().appendToLog(
                                    "Deferred user project staging cleanup: "
                                            + cleanupFailure.getMessage());
                        }
                    }
                }
            }
        }

        /** Removes one user-selected project without involving normal Play. */
        public boolean removeUserProject(
                MinecraftInstances instances, ProjectInfo project,
                boolean rememberManagedDisable) {
            synchronized(MOD_MANAGEMENT_LOCK) {
                if(instances == null || project == null
                        || !hasCompletedSeedOnlyOwnership()
                        || !seedRootMatchesGameDirectory()) {
                    return false;
                }
                ProjectInfo[] previousProjects = extProjects == null
                        ? new ProjectInfo[0] : extProjects;
                String[] previousDisabled = disabledMods == null
                        ? null : disabledMods.clone();
                File artifact = null;
                File backup = null;
                try {
                    int matchingEntries = 0;
                    for(ProjectInfo existing : previousProjects) {
                        if(existing != null && existing.slug != null
                                && existing.slug.equalsIgnoreCase(project.slug)) {
                            matchingEntries++;
                        }
                    }
                    if(matchingEntries != 1) {
                        throw new IOException(
                                "Ambiguous project metadata; removal was not attempted");
                    }
                    artifact = resolveExistingProjectArtifact(project);
                    String artifactPath = artifact.getCanonicalPath();
                    for(ProjectInfo existing : previousProjects) {
                        if(existing == null || existing.slug == null
                                || existing.slug.equalsIgnoreCase(project.slug)) {
                            continue;
                        }
                        if(resolveExistingProjectArtifact(existing).getCanonicalPath()
                                .equals(artifactPath)) {
                            throw new IOException(
                                    "Project artifact is shared with " + existing.slug);
                        }
                    }
                    if(artifact.isFile()) {
                        backup = new File(artifact.getParentFile(), artifact.getName()
                                + ".questcraft-remove-backup-" + System.nanoTime());
                        try {
                            Files.move(artifact.toPath(), backup.toPath(),
                                    StandardCopyOption.ATOMIC_MOVE);
                        } catch(AtomicMoveNotSupportedException ignored) {
                            Files.move(artifact.toPath(), backup.toPath());
                        }
                    }

                    ArrayList<ProjectInfo> retained = new ArrayList<>();
                    for(ProjectInfo existing : previousProjects) {
                        if(existing == null || existing.slug == null
                                || !existing.slug.equalsIgnoreCase(project.slug)) {
                            retained.add(existing);
                        }
                    }
                    extProjects = retained.toArray(new ProjectInfo[0]);
                    if(rememberManagedDisable) {
                        disableManagedMod(project.slug);
                    }
                    persistInstancesAtomically(instances);
                    if(backup != null) {
                        try {
                            Files.deleteIfExists(backup.toPath());
                        } catch(IOException cleanupFailure) {
                            Logger.getInstance().appendToLog(
                                    "Removed user project; stale backup cleanup was deferred: "
                                            + cleanupFailure.getMessage());
                        }
                    }
                    return true;
                } catch(Exception failure) {
                    extProjects = previousProjects;
                    disabledMods = previousDisabled;
                    try {
                        if(backup != null && backup.isFile() && artifact != null) {
                            try {
                                Files.move(backup.toPath(), artifact.toPath(),
                                        StandardCopyOption.ATOMIC_MOVE);
                            } catch(AtomicMoveNotSupportedException ignored) {
                                Files.move(backup.toPath(), artifact.toPath());
                            }
                        }
                    } catch(IOException rollbackFailure) {
                        Logger.getInstance().appendToLog(
                                "User project removal rollback failed: "
                                        + rollbackFailure.getMessage());
                    }
                    Logger.getInstance().appendToLog(
                            "User project removal failed: " + failure.getMessage());
                    return false;
                }
            }
        }

        private void updateModByType(
                Context ctx, List<ProjectInfo> newMods,
                boolean preserveMissingUnmanaged) throws IOException {
            ArrayList<ProjectInfo> newExtMods = new ArrayList<>();
            for(ProjectInfo extMod : extProjects) {
                boolean manual = true;
                for(ProjectInfo newMod : newMods) {
                    if(!extMod.slug.equals(newMod.slug)) {
                        continue;
                    }
                    manual = false;
                    boolean legacyMod = newMod.fileName == null;
                    File mod = new File(
                            gameDir + (newMod.type.equals("mod") ? "/mods" : "/resourcepacks"),
                            (legacyMod ? newMod.slug : newMod.fileName) + (newMod.type.equals("resourcepack") ? ".zip" : ".jar")
                    );
                    if(!mod.exists() || !extMod.version.equals(newMod.version) ||
                            !matchesExpectedHash(newMod, mod)) {
                        installProject(ctx, newMod, mod, false);
                        extMod = newMod;
                        break;
                    }
                }
                if(manual) {
                    boolean legacyMod = extMod.fileName == null;
                    File mod = new File(
                            gameDir + (extMod.type.equals("mod") ? "/mods" : "/resourcepacks"),
                            (legacyMod ? extMod.slug : extMod.fileName) + (extMod.type.equals("resourcepack") ? ".zip" : ".jar")
                    );
                    if(!mod.exists() && !preserveMissingUnmanaged) {
                        installProject(ctx, extMod, mod, true);
                    }
                }
                newExtMods.add(extMod);
            }

            // Existing instances used to update only projects already present
            // in extProjects. Install newly added managed mods as well so a
            // manifest update actually reaches an established profile.
            for(ProjectInfo newMod : newMods) {
                boolean alreadyPresent = false;
                for(ProjectInfo installedMod : newExtMods) {
                    if(installedMod.slug.equals(newMod.slug)) {
                        alreadyPresent = true;
                        break;
                    }
                }
                if(alreadyPresent) {
                    continue;
                }

                boolean legacyMod = newMod.fileName == null;
                File mod = new File(
                        gameDir + (newMod.type.equals("mod") ? "/mods" : "/resourcepacks"),
                        (legacyMod ? newMod.slug : newMod.fileName) + (newMod.type.equals("resourcepack") ? ".zip" : ".jar")
                );
                installProject(ctx, newMod, mod, false);
                newExtMods.add(newMod);
            }

            extProjects = newExtMods.toArray(new ProjectInfo[0]);
        }

        private void downloadAllMods(Context ctx, List<ProjectInfo> newMods) throws IOException {
            for(ProjectInfo newMod : newMods) {
                boolean legacyMod = newMod.fileName == null;
                File mod = new File(
                        gameDir + (newMod.type.equals("mod") ? "/mods" : "/resourcepacks"),
                        (legacyMod ? newMod.slug : newMod.fileName) + (newMod.type.equals("resourcepack") ? ".zip" : ".jar")
                );
                installProject(ctx, newMod, mod, true);
            }

            extProjects = newMods.toArray(new ProjectInfo[0]);
        }

        private ArrayList<ProjectInfo> selectManagedMods(ModsJson.Version version) {
            ArrayList<ProjectInfo> selected = new ArrayList<>(Arrays.asList(version.coreMods));
            if(defaultMods) {
                for(ProjectInfo project : version.defaultMods) {
                    if(!isManagedModDisabled(project.slug)) {
                        selected.add(project);
                    }
                }
            }
            return selected;
        }

        private void normalizeDisabledMods(ModsJson.Version version) {
            Set<String> coreSlugs = new LinkedHashSet<>();
            for(ProjectInfo core : version.coreMods) {
                coreSlugs.add(core.slug.toLowerCase(Locale.ROOT));
            }
            LinkedHashSet<String> normalized = normalizedDisabledMods();
            normalized.removeIf(slug -> coreSlugs.contains(slug.toLowerCase(Locale.ROOT)));
            disabledMods = normalized.toArray(new String[0]);
        }

        private void purgeDisabledManagedProjects(ModsJson.Version version) throws IOException {
            if(extProjects == null || disabledMods == null || disabledMods.length == 0) {
                return;
            }
            Set<String> defaultSlugs = new LinkedHashSet<>();
            for(ProjectInfo project : version.defaultMods) {
                defaultSlugs.add(project.slug.toLowerCase(Locale.ROOT));
            }
            ArrayList<ProjectInfo> retained = new ArrayList<>();
            for(ProjectInfo project : extProjects) {
                boolean disabled = project != null && project.slug != null &&
                        defaultSlugs.contains(project.slug.toLowerCase(Locale.ROOT)) &&
                        isManagedModDisabled(project.slug);
                if(!disabled) {
                    retained.add(project);
                    continue;
                }
                boolean legacy = project.fileName == null;
                String extension = "resourcepack".equals(project.type) ? ".zip" : ".jar";
                File artifact = new File(gameDir + ("resourcepack".equals(project.type)
                        ? "/resourcepacks/" : "/mods/"),
                        (legacy ? project.slug : project.fileName) + extension);
                Files.deleteIfExists(artifact.toPath());
                Logger.getInstance().appendToLog("Keeping managed mod disabled: " + project.slug);
            }
            extProjects = retained.toArray(new ProjectInfo[0]);
        }

        /**
         * Repairs only pinned managed mods embedded in this APK. This method
         * never reads a URL and is safe to run before the network probe.
         */
        public boolean reconcileBundledManagedMods(Context ctx, MinecraftInstances instances) {
            synchronized(MOD_MANAGEMENT_LOCK) {
                return reconcileBundledManagedModsLocked(ctx, instances);
            }
        }

        private boolean reconcileBundledManagedModsLocked(
                Context ctx, MinecraftInstances instances) {
            if(!requiresQuestVulkanBackend()) {
                return true;
            }
            if(isPersonalSeedOnlyProfile(ctx)) {
                if(preservesUserManagedMods(ctx)) {
                    Logger.getInstance().appendToLog(
                            "Seed-only mod policy: preserving user-selected mod files.");
                    return true;
                }
                Logger.getInstance().appendToLog(
                        "Seed-only mod policy is not initialized; refusing automatic reconciliation.");
                return false;
            }

            String manifestAsset = API.developerMods ? "devmods.json" : "mods.json";
            try(InputStream input = ctx.getAssets().open(manifestAsset);
                    InputStreamReader reader = new InputStreamReader(input, StandardCharsets.UTF_8)) {
                ModsJson manifest = GsonUtils.GLOBAL_GSON.fromJson(reader, ModsJson.class);
                BundledManagedModsReconciler.Outcome outcome =
                        BundledManagedModsReconciler.reconcile(
                                this,
                                manifest,
                                assetPath -> readBundledAsset(ctx, assetPath));
                if(outcome.metadataChanged) {
                    persistInstancesAtomically(instances);
                }
                if(outcome.artifactsChanged || outcome.metadataChanged) {
                    Logger.getInstance().appendToLog(
                            "Reconciled pinned APK-managed mods from local assets.");
                }
                return true;
            } catch(Exception failure) {
                Logger.getInstance().appendToLog(
                        "Bundled managed-mod reconciliation failed; launch aborted safely: "
                                + failure.getMessage());
                return false;
            }
        }

        private static byte[] readBundledAsset(Context ctx, String assetPath) throws IOException {
            try(InputStream input = ctx.getAssets().open(assetPath);
                    ByteArrayOutputStream output = new ByteArrayOutputStream()) {
                byte[] buffer = new byte[64 * 1024];
                int read;
                while((read = input.read(buffer)) != -1) {
                    output.write(buffer, 0, read);
                }
                return output.toByteArray();
            }
        }

        private static void persistInstancesAtomically(MinecraftInstances instances)
                throws IOException {
            synchronized(MOD_MANAGEMENT_LOCK) {
                File destination = new File(Constants.USER_HOME, "instances.json");
                File parent = destination.getParentFile();
                if(parent == null || (!parent.isDirectory() && !parent.mkdirs())) {
                    throw new IOException("Could not create launcher metadata directory");
                }
                File staged = new File(parent, "instances.json.questcraft-bundled-stage");
                Files.deleteIfExists(staged.toPath());
                try {
                    Files.write(staged.toPath(),
                            (GsonUtils.GLOBAL_GSON.toJson(instances) + "\n")
                                    .getBytes(StandardCharsets.UTF_8));
                    try {
                        Files.move(staged.toPath(), destination.toPath(),
                                StandardCopyOption.ATOMIC_MOVE, StandardCopyOption.REPLACE_EXISTING);
                    } catch(AtomicMoveNotSupportedException ignored) {
                        Files.move(staged.toPath(), destination.toPath(),
                                StandardCopyOption.REPLACE_EXISTING);
                    }
                } finally {
                    Files.deleteIfExists(staged.toPath());
                }
            }
        }

        public boolean updateMods(Context ctx, MinecraftInstances instances) {
            synchronized(MOD_MANAGEMENT_LOCK) {
                return updateMods(ctx, instances, false, false);
            }
        }

        /** Installs the initial known-compatible stack for a newly created profile. */
        public boolean seedManagedMods(Context ctx, MinecraftInstances instances) {
            synchronized(MOD_MANAGEMENT_LOCK) {
                return updateMods(ctx, instances, true, false);
            }
        }

        /** Explicit recovery operation; normal Personal Play never calls this path. */
        public boolean repairManagedMods(Context ctx, MinecraftInstances instances) {
            synchronized(MOD_MANAGEMENT_LOCK) {
                if(!preservesUserManagedMods(ctx)) {
                    return false;
                }
                return updateMods(ctx, instances, true, true);
            }
        }

        private boolean updateMods(
                Context ctx, MinecraftInstances instances, boolean explicitSeedOrRepair,
                boolean preserveMissingUnmanaged) {
            if(extProjects == null) {
                extProjects = new ProjectInfo[0];
            }
            if(isPersonalSeedOnlyProfile(ctx) && !explicitSeedOrRepair) {
                if(preservesUserManagedMods(ctx)) {
                    Logger.getInstance().appendToLog(
                            "Seed-only mod policy: automatic mod reconciliation skipped.");
                    return true;
                }
                Logger.getInstance().appendToLog(
                        "Seed-only mod policy is not initialized; explicit initial seed required.");
                return false;
            }
            if(explicitSeedOrRepair && !preserveMissingUnmanaged
                    && preservesUserManagedMods(ctx)) {
                Logger.getInstance().appendToLog(
                        "Seed-only mod policy: initial seed already completed.");
                return true;
            }
            Boolean previousSeeded = managedModsSeeded;
            String previousSeedRoot = managedModsSeedRoot;
            try {
                ModsJson newMods = downloadCurrentModsJson(ctx, Constants.USER_HOME);
                if(newMods == null || newMods.versions == null) {
                    throw new IOException("Managed manifest is missing or invalid");
                }
                ModsJson.Version targetVersion = null;
                for (ModsJson.Version newVersion : newMods.versions) {
                    if (versionName.equals(newVersion.name)) {
                        targetVersion = newVersion;
                        break;
                    }
                }
                if(targetVersion == null) {
                    throw new IOException(
                            "Managed manifest has no entry for Minecraft " + versionName);
                }

                ModsJson oldMods = parseModsJson(Constants.USER_HOME + "/mods.json");
                if(oldMods != null && !explicitSeedOrRepair
                        && !preserveMissingUnmanaged) {
                    removeOldMods(oldMods, newMods);
                }

                normalizeDisabledMods(targetVersion);
                purgeDisabledManagedProjects(targetVersion);
                ArrayList<ProjectInfo> mergedNewMods = selectManagedMods(targetVersion);
                File modsFolder = new File(gameDir + "/mods");
                if((extProjects.length == 0 || !modsFolder.exists())
                        && !preserveMissingUnmanaged) {
                    downloadAllMods(ctx, mergedNewMods);
                } else {
                    updateModByType(ctx, mergedNewMods, preserveMissingUnmanaged);
                }

                File newModsFile = new File(Constants.USER_HOME + "/new_mods.json");
                File modsFile = new File(Constants.USER_HOME + "/mods.json");

                try {
                    Files.move(newModsFile.toPath(), modsFile.toPath(),
                            StandardCopyOption.ATOMIC_MOVE, StandardCopyOption.REPLACE_EXISTING);
                } catch(AtomicMoveNotSupportedException ignored) {
                    Files.move(newModsFile.toPath(), modsFile.toPath(),
                            StandardCopyOption.REPLACE_EXISTING);
                }

                if(usesSeedOnlyModManagement()) {
                    managedModsSeeded = Boolean.TRUE;
                    managedModsSeedRoot = new File(gameDir).getCanonicalPath();
                    Logger.getInstance().appendToLog(
                            "Seed-only mod policy: initial managed stack installed; future changes are user-owned.");
                }
                persistInstancesAtomically(instances);
                return true;
            } catch (Exception e) {
                managedModsSeeded = previousSeeded;
                managedModsSeedRoot = previousSeedRoot;
                try {
                    Files.deleteIfExists(new File(
                            Constants.USER_HOME, "new_mods.json").toPath());
                } catch(IOException ignored) {}
                Logger.getInstance().appendToLog("Mods failed to download! Are you offline?\n" + e);
                return false;
            }
        }
    }
}
