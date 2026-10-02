package pojlib.util.json;

import java.io.File;
import java.io.FileInputStream;
import java.io.IOException;
import java.nio.file.AtomicMoveNotSupportedException;
import java.nio.file.Files;
import java.nio.file.StandardCopyOption;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.LinkedHashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Set;

/**
 * Reconciles only launcher-managed projects that are embedded in the APK.
 *
 * <p>This class deliberately has no downloader or Android dependency. The
 * caller supplies bytes from {@code AssetManager}; URL-backed projects are
 * ignored and remain the responsibility of the connected update path.</p>
 */
final class BundledManagedModsReconciler {
    private static final String REQUIRED_CORE_SLUG = "Vivecraft";
    private static final String ASSET_PREFIX = "asset://mods/";

    interface AssetSource {
        byte[] read(String assetPath) throws IOException;
    }

    static final class Outcome {
        final boolean artifactsChanged;
        final boolean metadataChanged;

        Outcome(boolean artifactsChanged, boolean metadataChanged) {
            this.artifactsChanged = artifactsChanged;
            this.metadataChanged = metadataChanged;
        }
    }

    private BundledManagedModsReconciler() {}

    static Outcome reconcile(
            MinecraftInstances.Instance instance,
            ModsJson manifest,
            AssetSource assetSource) throws IOException {
        if(instance == null || instance.gameDir == null || instance.versionName == null) {
            throw new IOException("Selected instance is incomplete");
        }

        ModsJson.Version version = requireVersion(manifest, instance.versionName);
        List<ProjectInfo> enabled = new ArrayList<>();
        List<ProjectInfo> explicitlyDisabled = new ArrayList<>();
        Map<String, ProjectInfo> assetProjects = new LinkedHashMap<>();
        Set<String> coreSlugs = new LinkedHashSet<>();

        ProjectInfo requiredCore = null;
        for(ProjectInfo project : version.coreMods) {
            if(project != null && hasText(project.slug)) {
                coreSlugs.add(normalizeSlug(project.slug));
            }
            if(project != null && REQUIRED_CORE_SLUG.equalsIgnoreCase(project.slug)) {
                if(requiredCore != null) {
                    throw new IOException("Bundled manifest contains duplicate Vivecraft core entries");
                }
                requiredCore = project;
            }
            if(isAssetBacked(project)) {
                validateAssetProject(project);
                registerUnique(assetProjects, project);
                enabled.add(project);
            }
        }
        if(requiredCore == null) {
            throw new IOException("Bundled manifest does not declare the required Vivecraft core");
        }
        validateAssetProject(requiredCore);

        Set<String> disabled = normalizeDisabled(instance.disabledMods, coreSlugs);
        if(instance.defaultMods) {
            for(ProjectInfo project : version.defaultMods) {
                if(!isAssetBacked(project)) {
                    continue;
                }
                validateAssetProject(project);
                registerUnique(assetProjects, project);
                if(disabled.contains(normalizeSlug(project.slug))) {
                    explicitlyDisabled.add(project);
                } else {
                    enabled.add(project);
                }
            }
        } else {
            // An explicitly disabled bundled optional stays disabled even if
            // default mods are currently off. Do not otherwise remove optional
            // projects merely because the profile toggled its default set.
            for(ProjectInfo project : version.defaultMods) {
                if(isAssetBacked(project)
                        && disabled.contains(normalizeSlug(project.slug))) {
                    validateAssetProject(project);
                    registerUnique(assetProjects, project);
                    explicitlyDisabled.add(project);
                }
            }
        }

        // Validate every enabled asset before the first filesystem mutation.
        Map<String, byte[]> verifiedAssets = new LinkedHashMap<>();
        for(ProjectInfo project : enabled) {
            String assetPath = project.download_link.substring("asset://".length());
            byte[] contents = assetSource.read(assetPath);
            if(contents == null || contents.length == 0) {
                throw new IOException("Bundled asset is missing for " + project.slug);
            }
            if(!project.sha256.equalsIgnoreCase(sha256(contents))) {
                throw new IOException("Bundled asset SHA-256 mismatch for " + project.slug);
            }
            verifiedAssets.put(normalizeSlug(project.slug), contents);
        }

        boolean artifactsChanged = false;
        for(ProjectInfo project : enabled) {
            File destination = destination(instance, project);
            if(!matches(project, destination)) {
                installAtomically(destination, verifiedAssets.get(normalizeSlug(project.slug)));
                if(!matches(project, destination)) {
                    throw new IOException("Installed bundled project failed verification: " + project.slug);
                }
                artifactsChanged = true;
            }
        }

        for(ProjectInfo project : explicitlyDisabled) {
            File destination = destination(instance, project);
            if(Files.deleteIfExists(destination.toPath())) {
                artifactsChanged = true;
            }
        }

        ProjectInfo[] previousProjects = instance.extProjects == null
                ? new ProjectInfo[0]
                : instance.extProjects;
        ProjectInfo[] reconciledProjects = reconcileMetadata(
                instance, previousProjects, enabled, explicitlyDisabled);
        String[] normalizedDisabled = disabled.toArray(new String[0]);
        boolean metadataChanged = !sameProjects(previousProjects, reconciledProjects)
                || !Arrays.equals(instance.disabledMods == null ? new String[0] : instance.disabledMods,
                        normalizedDisabled);
        instance.extProjects = reconciledProjects;
        instance.disabledMods = normalizedDisabled;
        return new Outcome(artifactsChanged, metadataChanged);
    }

    private static ModsJson.Version requireVersion(ModsJson manifest, String versionName)
            throws IOException {
        if(manifest == null || manifest.versions == null) {
            throw new IOException("Bundled managed-mod manifest has no versions array");
        }
        ModsJson.Version selected = null;
        for(ModsJson.Version candidate : manifest.versions) {
            if(candidate == null || !versionName.equals(candidate.name)) {
                continue;
            }
            if(selected != null) {
                throw new IOException("Bundled manifest contains duplicate version " + versionName);
            }
            selected = candidate;
        }
        if(selected == null) {
            throw new IOException("Bundled manifest has no entry for Minecraft " + versionName);
        }
        if(selected.coreMods == null || selected.defaultMods == null) {
            throw new IOException("Bundled manifest has incomplete project arrays for " + versionName);
        }
        return selected;
    }

    private static boolean isAssetBacked(ProjectInfo project) {
        return project != null && project.download_link != null
                && project.download_link.startsWith("asset://");
    }

    private static void validateAssetProject(ProjectInfo project) throws IOException {
        if(project == null || !hasText(project.slug) || !hasText(project.version)) {
            throw new IOException("Bundled managed project is missing identity metadata");
        }
        if(!"mod".equals(project.type)) {
            throw new IOException("Bundled managed project must be a mod: " + project.slug);
        }
        if(project.download_link == null
                || !project.download_link.startsWith(ASSET_PREFIX)
                || project.download_link.contains("..")
                || project.download_link.indexOf('\\') >= 0) {
            throw new IOException("Bundled managed project has an unsafe asset path: " + project.slug);
        }
        String relativeAsset = project.download_link.substring("asset://".length());
        if(relativeAsset.length() <= "mods/".length()
                || relativeAsset.substring("mods/".length()).contains("/")) {
            throw new IOException("Bundled managed project must be a direct mods asset: " + project.slug);
        }
        if(!project.sha256.matches("(?i)^[0-9a-f]{64}$")) {
            throw new IOException("Bundled managed project is missing a valid SHA-256 pin: " + project.slug);
        }
        validateFileComponent(project.slug, "slug");
        if(project.fileName != null) {
            validateFileComponent(project.fileName, "filename");
        }
    }

    private static void registerUnique(Map<String, ProjectInfo> projects, ProjectInfo project)
            throws IOException {
        String key = normalizeSlug(project.slug);
        if(projects.put(key, project) != null) {
            throw new IOException("Bundled manifest contains duplicate asset project " + project.slug);
        }
    }

    private static Set<String> normalizeDisabled(String[] values, Set<String> coreSlugs) {
        LinkedHashSet<String> result = new LinkedHashSet<>();
        if(values == null) {
            return result;
        }
        for(String value : values) {
            if(!hasText(value)) {
                continue;
            }
            String normalized = normalizeSlug(value);
            if(!coreSlugs.contains(normalized)) {
                result.add(normalized);
            }
        }
        return result;
    }

    private static ProjectInfo[] reconcileMetadata(
            MinecraftInstances.Instance instance,
            ProjectInfo[] existing,
            List<ProjectInfo> enabled,
            List<ProjectInfo> disabled) throws IOException {
        Map<String, ProjectInfo> enabledBySlug = bySlug(enabled);
        Map<String, ProjectInfo> disabledBySlug = bySlug(disabled);
        Set<String> emitted = new LinkedHashSet<>();
        ArrayList<ProjectInfo> reconciled = new ArrayList<>();

        for(ProjectInfo current : existing) {
            if(current == null || !hasText(current.slug)) {
                reconciled.add(current);
                continue;
            }
            String slug = normalizeSlug(current.slug);
            ProjectInfo selected = enabledBySlug.get(slug);
            ProjectInfo blocked = disabledBySlug.get(slug);
            if(selected != null && sameArtifactSlot(instance, current, selected)) {
                if(emitted.add(slug)) {
                    reconciled.add(selected);
                }
            } else if(blocked != null && sameArtifactSlot(instance, current, blocked)) {
                // Explicitly disabled launcher-owned slot: remove metadata as
                // well as the canonical artifact so Fabric cannot load it.
            } else {
                reconciled.add(current);
            }
        }

        for(ProjectInfo selected : enabled) {
            String slug = normalizeSlug(selected.slug);
            if(emitted.add(slug)) {
                reconciled.add(selected);
            }
        }
        return reconciled.toArray(new ProjectInfo[0]);
    }

    private static Map<String, ProjectInfo> bySlug(List<ProjectInfo> projects) {
        Map<String, ProjectInfo> result = new LinkedHashMap<>();
        for(ProjectInfo project : projects) {
            result.put(normalizeSlug(project.slug), project);
        }
        return result;
    }

    private static boolean sameArtifactSlot(
            MinecraftInstances.Instance instance,
            ProjectInfo left,
            ProjectInfo right) throws IOException {
        return destination(instance, left).equals(destination(instance, right));
    }

    private static File destination(MinecraftInstances.Instance instance, ProjectInfo project)
            throws IOException {
        String baseName = project.fileName == null ? project.slug : project.fileName;
        validateFileComponent(baseName, project.fileName == null ? "slug" : "filename");
        File modsDirectory = new File(instance.gameDir, "mods").getCanonicalFile();
        File destination = new File(modsDirectory, baseName + ".jar").getCanonicalFile();
        if(!destination.getParentFile().equals(modsDirectory)) {
            throw new IOException("Bundled project resolves outside the mods directory: " + project.slug);
        }
        return destination;
    }

    private static void validateFileComponent(String value, String label) throws IOException {
        if(!hasText(value)
                || value.contains("..")
                || value.indexOf('/') >= 0
                || value.indexOf('\\') >= 0
                || new File(value).isAbsolute()) {
            throw new IOException("Bundled project has an unsafe " + label + ": " + value);
        }
    }

    private static boolean matches(ProjectInfo project, File file) throws IOException {
        return file.isFile() && project.sha256.equalsIgnoreCase(sha256(file));
    }

    private static void installAtomically(File destination, byte[] contents) throws IOException {
        File parent = destination.getParentFile();
        if(parent == null || (!parent.isDirectory() && !parent.mkdirs())) {
            throw new IOException("Could not create bundled-mod directory");
        }
        File staged = new File(parent, destination.getName() + ".questcraft-bundled-stage");
        Files.deleteIfExists(staged.toPath());
        try {
            Files.write(staged.toPath(), contents);
            try {
                Files.move(staged.toPath(), destination.toPath(),
                        StandardCopyOption.ATOMIC_MOVE, StandardCopyOption.REPLACE_EXISTING);
            } catch(AtomicMoveNotSupportedException ignored) {
                Files.move(staged.toPath(), destination.toPath(), StandardCopyOption.REPLACE_EXISTING);
            }
        } finally {
            Files.deleteIfExists(staged.toPath());
        }
    }

    private static String sha256(byte[] contents) {
        return hex(digest().digest(contents));
    }

    private static String sha256(File file) throws IOException {
        MessageDigest digest = digest();
        try(FileInputStream input = new FileInputStream(file)) {
            byte[] buffer = new byte[64 * 1024];
            int read;
            while((read = input.read(buffer)) != -1) {
                digest.update(buffer, 0, read);
            }
        }
        return hex(digest.digest());
    }

    private static MessageDigest digest() {
        try {
            return MessageDigest.getInstance("SHA-256");
        } catch(NoSuchAlgorithmException impossible) {
            throw new IllegalStateException("SHA-256 is unavailable", impossible);
        }
    }

    private static String hex(byte[] digest) {
        StringBuilder result = new StringBuilder(digest.length * 2);
        for(byte value : digest) {
            result.append(String.format(Locale.ROOT, "%02x", value & 0xff));
        }
        return result.toString();
    }

    private static boolean sameProjects(ProjectInfo[] left, ProjectInfo[] right) {
        if(left.length != right.length) {
            return false;
        }
        for(int index = 0; index < left.length; index++) {
            if(!sameProject(left[index], right[index])) {
                return false;
            }
        }
        return true;
    }

    private static boolean sameProject(ProjectInfo left, ProjectInfo right) {
        if(left == right) {
            return true;
        }
        if(left == null || right == null) {
            return false;
        }
        return equal(left.slug, right.slug)
                && equal(left.fileName, right.fileName)
                && equal(left.version, right.version)
                && equal(left.type, right.type)
                && equal(left.download_link, right.download_link)
                && equal(left.sha256, right.sha256);
    }

    private static boolean equal(String left, String right) {
        return left == null ? right == null : left.equals(right);
    }

    private static String normalizeSlug(String value) {
        return value.trim().toLowerCase(Locale.ROOT);
    }

    private static boolean hasText(String value) {
        return value != null && !value.trim().isEmpty();
    }
}
