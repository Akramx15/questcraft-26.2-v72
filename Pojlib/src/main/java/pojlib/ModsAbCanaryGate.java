package pojlib;

import android.app.Activity;

import com.google.gson.Gson;

import java.io.File;
import java.io.IOException;
import java.io.InputStream;
import java.io.InputStreamReader;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.LinkOption;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.util.Collections;
import java.util.Locale;

import pojlib.util.Constants;
import pojlib.util.Logger;
import pojlib.util.json.MinecraftInstances;
import pojlib.util.json.ModsJson;
import pojlib.util.json.ProjectInfo;

/**
 * Lab-only gate for one-variable Sodium/Lithium/FerriteCore/BadOptimizations
 * A/B experiments.  The gate is dormant unless an exact, Host-armed marker
 * exists after normal managed-mod reconciliation.
 */
final class ModsAbCanaryGate {
    static final String HARNESS_ID = "questcraft-mods-ab-canary-v1";
    static final String EXPECTED_PACKAGE = "com.qcxr.qcxr.canary262";
    static final String PROFILE = "26.2";
    static final String VERSION = "26.2";
    static final String STATE_RELATIVE = ".questcraft/" + HARNESS_ID;

    static final String SODIUM_BASELINE_SHA256 =
            "a6d1ced177a1c57147e8c1c8043650d5f93e1f2824c9952f3fb67ae05633a0a7";
    static final String SODIUM_CANDIDATE_SHA256 =
            "de406c7a0ca5e748dfbe44740278400882a44e3109e2584b243ec02d4003344b";
    static final String LITHIUM_BASELINE_SHA256 =
            "fdde92e238e8075f89ad7f701f2a3d5854af88ba9a67657184a4407b104ac563";
    static final String FERRITE_BASELINE_SHA256 =
            "213966c72ed967acc7392beb28a866fba301ff56b9976c2e7801c2db7de6bf22";
    static final String BAD_OPTIMIZATIONS_BASELINE_SHA256 =
            "06cee46d81d3a0afb8e993dfbe4b990a3be92f52abde3590cc396490cb6eb4d2";

    private static final Spec SODIUM = new Spec(
            "sodium-0.9.1", "Sodium", "mods/Sodium.jar", "sodium",
            "mc26.2-0.9.2-alpha.4-fabric", SODIUM_BASELINE_SHA256, 1_880_490L,
            SODIUM_CANDIDATE_SHA256, 1_834_384L, "0.9.1+mc26.2", false);
    private static final Spec LITHIUM = new Spec(
            "without-lithium", "Lithium", "mods/Lithium.jar", "lithium",
            "mc26.2-0.25.3-fabric", LITHIUM_BASELINE_SHA256, 912_850L,
            ModsAbDisableTransaction.ABSENT_SHA256, 0L,
            ModsAbDisableTransaction.ABSENT_VALUE, true);
    private static final Spec FERRITE = new Spec(
            "without-ferrite-core", "Ferrite-Core", "mods/Ferrite-Core.jar", "ferritecore",
            "9.0.0-fabric", FERRITE_BASELINE_SHA256, 72_677L,
            ModsAbDisableTransaction.ABSENT_SHA256, 0L,
            ModsAbDisableTransaction.ABSENT_VALUE, true);
    private static final Spec BAD_OPTIMIZATIONS = new Spec(
            "without-bad-optimizations", "BadOptimizations",
            "mods/BadOptimizations.jar", "badoptimizations", "2.4.1",
            BAD_OPTIMIZATIONS_BASELINE_SHA256, 60_709L,
            ModsAbDisableTransaction.ABSENT_SHA256, 0L,
            ModsAbDisableTransaction.ABSENT_VALUE, true);
    private static final Spec[] SPECS = {SODIUM, LITHIUM, FERRITE, BAD_OPTIMIZATIONS};

    private static volatile ProcessPermit processPermit;

    private ModsAbCanaryGate() {
    }

    static boolean restorePriorProcessPermit(
            Activity activity, MinecraftInstances.Instance instance) {
        // Package authorization is intentionally evaluated before inspecting
        // process-local Lab state.  Stable cannot trigger a Lab rollback.
        if(activity == null || !EXPECTED_PACKAGE.equals(activity.getPackageName())) {
            return true;
        }
        if(processPermit == null) {
            return true;
        }
        return abortPromotedCandidate();
    }

    static boolean prepare(Activity activity, MinecraftInstances.Instance instance) {
        if(activity == null || instance == null || !PROFILE.equals(instance.instanceName) ||
                !VERSION.equals(instance.versionName) || instance.gameDir == null) {
            return true;
        }
        // This must precede every path construction, marker probe, and permit
        // inspection so Stable is a literal filesystem no-op.
        if(!EXPECTED_PACKAGE.equals(activity.getPackageName())) {
            return true;
        }

        Path gameDirectory = Paths.get(instance.gameDir).toAbsolutePath().normalize();
        Path stateDirectory = gameDirectory.resolve(STATE_RELATIVE).normalize();
        Path markerPath = stateDirectory.resolve("request.json");
        if(processPermit != null && !abortPromotedCandidate()) {
            Logger.getInstance().appendToLog(
                    "Mods A/B canary: prior process-local experiment could not be restored");
            return false;
        }
        if(!Files.exists(markerPath, LinkOption.NOFOLLOW_LINKS)) {
            return true;
        }
        if(VivecraftCoreCanaryGate.hasProcessPermit() || VeqCanaryGate.hasProcessPermit()) {
            Logger.getInstance().appendToLog(
                    "Mods A/B canary: concurrent canary permits are forbidden");
            return false;
        }

        try {
            validateGameDirectory(gameDirectory, stateDirectory);
            VivecraftCoreCanaryTransaction.Marker marker =
                    VivecraftCoreCanaryTransaction.readMarker(markerPath);
            Spec spec = specForTarget(marker.target);
            validateManifestLock(activity, spec);
            // A/B isolation starts from the full APK-managed stack, not merely
            // from a matching selected target. This keeps VEQ, ImmersiveMC,
            // Xaero and every other managed artifact hash-exact before the one
            // allowed variable is changed.
            if(!UnattendedStackVerifier.verify(activity, instance)) {
                throw new IOException("managed baseline stack is not exact");
            }
            Path target = gameDirectory.resolve(spec.target).normalize();
            if(!target.startsWith(gameDirectory.resolve("mods").normalize())) {
                throw new IOException("managed mod target escaped the profile");
            }
            VivecraftCoreCanaryTransaction.Layout layout =
                    new VivecraftCoreCanaryTransaction.Layout(stateDirectory, target);
            String otherModsFingerprint = VivecraftCoreCanaryTransaction.fingerprintOtherMods(
                    gameDirectory.resolve("mods"), target);

            if(spec.disabled) {
                ModsAbDisableTransaction.Contract contract =
                        new ModsAbDisableTransaction.Contract(
                                HARNESS_ID, EXPECTED_PACKAGE, PROFILE, spec.target,
                                spec.fabricId, spec.baselineSha256, spec.baselineSizeBytes,
                                otherModsFingerprint, System.currentTimeMillis());
                ModsAbDisableTransaction.Result result = ModsAbDisableTransaction.execute(
                        layout, contract, ModsAbDisableTransaction.NO_FAULTS);
                if(result.outcome == ModsAbDisableTransaction.Outcome.PROMOTED) {
                    processPermit = new ProcessPermit(spec, null, result.permit);
                    Logger.getInstance().appendToLog(
                            "Mods A/B canary: " + spec.experimentId + " permitted for one process");
                    return true;
                }
                if(result.mayLaunch()) {
                    Logger.getInstance().appendToLog(
                            "Mods A/B canary: baseline retained (" + result.detail + ")");
                    return true;
                }
                Logger.getInstance().appendToLog(
                        "Mods A/B canary: launch aborted safely (" + result.detail + ")");
                return false;
            }

            VivecraftCoreCanaryTransaction.Contract contract =
                    new VivecraftCoreCanaryTransaction.Contract(
                            HARNESS_ID, EXPECTED_PACKAGE, PROFILE, spec.target,
                            spec.baselineSha256, spec.baselineSizeBytes,
                            otherModsFingerprint, System.currentTimeMillis(),
                            spec.fabricId, spec.candidateVersion,
                            VivecraftCoreCanaryTransaction.ABSENT_DEPENDENCY,
                            VivecraftCoreCanaryTransaction.ABSENT_DEPENDENCY,
                            Collections.singleton(spec.candidateSha256));
            VivecraftCoreCanaryTransaction.Result result =
                    VivecraftCoreCanaryTransaction.execute(
                            layout, contract, VivecraftCoreCanaryTransaction.NO_FAULTS);
            if(result.outcome == VivecraftCoreCanaryTransaction.Outcome.PROMOTED) {
                processPermit = new ProcessPermit(spec, result.permit, null);
                Logger.getInstance().appendToLog(
                        "Mods A/B canary: sodium-0.9.1 permitted for one process");
                return true;
            }
            if(result.mayLaunch()) {
                Logger.getInstance().appendToLog(
                        "Mods A/B canary: baseline retained (" + result.detail + ")");
                return true;
            }
            Logger.getInstance().appendToLog(
                    "Mods A/B canary: launch aborted safely (" + result.detail + ")");
            return false;
        } catch(IOException | RuntimeException failure) {
            processPermit = null;
            Logger.getInstance().appendToLog(
                    "Mods A/B canary: prelaunch rejected safely (" +
                            failure.getClass().getSimpleName() + ")");
            return false;
        }
    }

    static boolean hasProcessPermit() {
        return processPermit != null;
    }

    static boolean handlesProject(ProjectInfo project) {
        ProcessPermit permit = processPermit;
        return permit != null && project != null && permit.spec.slug.equals(project.slug);
    }

    static boolean verifyManagedArtifact(MinecraftInstances.Instance instance,
                                         ProjectInfo project, File artifact) {
        ProcessPermit permit = processPermit;
        if(permit == null || instance == null || project == null || artifact == null ||
                !permit.spec.slug.equals(project.slug) ||
                !PROFILE.equals(instance.instanceName) || !VERSION.equals(instance.versionName) ||
                instance.gameDir == null) {
            return false;
        }
        try {
            Path target = artifact.toPath().toAbsolutePath().normalize();
            String fingerprint = VivecraftCoreCanaryTransaction.fingerprintOtherMods(
                    target.getParent(), target);
            if(permit.spec.disabled) {
                return ModsAbDisableTransaction.permitMatchesAbsence(
                        permit.disablePermit, target, fingerprint);
            }
            long size = Files.size(target);
            String hash = VivecraftCoreCanaryTransaction.sha256(target);
            return permit.spec.candidateSha256.equals(hash) &&
                    VivecraftCoreCanaryTransaction.permitMatches(
                            permit.replacePermit, target, hash, size, fingerprint);
        } catch(IOException | RuntimeException ignored) {
            return false;
        }
    }

    static boolean abortPromotedCandidate() {
        ProcessPermit permit = processPermit;
        processPermit = null;
        if(permit == null) {
            return true;
        }
        boolean restored = permit.spec.disabled
                ? ModsAbDisableTransaction.restoreAfterFailure(permit.disablePermit)
                : VivecraftCoreCanaryTransaction.restoreAfterFailure(permit.replacePermit);
        Logger.getInstance().appendToLog(restored
                ? "Mods A/B canary: exact baseline restored"
                : "Mods A/B canary: baseline restoration failed; launch remains aborted");
        return restored;
    }

    private static Spec specForTarget(String target) throws IOException {
        Spec match = null;
        for(Spec spec : SPECS) {
            if(spec.target.equals(target)) {
                if(match != null) {
                    throw new IOException("ambiguous experiment target");
                }
                match = spec;
            }
        }
        if(match == null) {
            throw new IOException("target is outside the fixed experiment allowlist");
        }
        return match;
    }

    private static void validateManifestLock(Activity activity, Spec spec) throws IOException {
        try(InputStream stream = activity.getAssets().open("mods.json");
                InputStreamReader reader = new InputStreamReader(stream, StandardCharsets.UTF_8)) {
            ModsJson manifest = new Gson().fromJson(reader, ModsJson.class);
            if(manifest == null || manifest.versions == null) {
                throw new IOException("bundled managed manifest is missing");
            }
            ProjectInfo match = null;
            for(ModsJson.Version version : manifest.versions) {
                if(version == null || !VERSION.equals(version.name) || version.defaultMods == null) {
                    continue;
                }
                for(ProjectInfo project : version.defaultMods) {
                    if(project != null && spec.slug.equals(project.slug)) {
                        if(match != null) {
                            throw new IOException("bundled manifest has duplicate experiment entries");
                        }
                        match = project;
                    }
                }
            }
            if(match == null || match.fileName != null ||
                    !spec.manifestVersion.equals(match.version) || match.sha256 == null ||
                    !spec.baselineSha256.equals(match.sha256.toLowerCase(Locale.ROOT))) {
                throw new IOException("bundled managed-mod lock changed");
            }
        } catch(RuntimeException e) {
            throw new IOException("could not parse bundled managed manifest", e);
        }
    }

    private static void validateGameDirectory(Path gameDirectory, Path stateDirectory)
            throws IOException {
        if(Constants.USER_HOME == null) {
            throw new IOException("launcher home is unavailable");
        }
        Path expected = Paths.get(Constants.USER_HOME).toAbsolutePath().normalize()
                .resolve("instances").resolve(PROFILE).normalize();
        if(!stateDirectory.startsWith(gameDirectory) || Files.isSymbolicLink(gameDirectory) ||
                Files.isSymbolicLink(stateDirectory) ||
                !Files.isDirectory(gameDirectory, LinkOption.NOFOLLOW_LINKS) ||
                !Files.isDirectory(stateDirectory, LinkOption.NOFOLLOW_LINKS)) {
            throw new IOException("Mods A/B canary path is outside the exact profile");
        }
        Path realGame = gameDirectory.toRealPath(LinkOption.NOFOLLOW_LINKS);
        Path realExpected = expected.toRealPath(LinkOption.NOFOLLOW_LINKS);
        Path realState = stateDirectory.toRealPath(LinkOption.NOFOLLOW_LINKS);
        if(!realGame.equals(realExpected) || !realState.startsWith(realGame)) {
            throw new IOException("Mods A/B canary state directory escaped the profile");
        }
    }

    private static final class ProcessPermit {
        final Spec spec;
        final VivecraftCoreCanaryTransaction.Permit replacePermit;
        final ModsAbDisableTransaction.Permit disablePermit;

        ProcessPermit(Spec spec, VivecraftCoreCanaryTransaction.Permit replacePermit,
                      ModsAbDisableTransaction.Permit disablePermit) {
            this.spec = spec;
            this.replacePermit = replacePermit;
            this.disablePermit = disablePermit;
        }
    }

    private static final class Spec {
        final String experimentId;
        final String slug;
        final String target;
        final String fabricId;
        final String manifestVersion;
        final String baselineSha256;
        final long baselineSizeBytes;
        final String candidateSha256;
        final long candidateSizeBytes;
        final String candidateVersion;
        final boolean disabled;

        Spec(String experimentId, String slug, String target, String fabricId,
             String manifestVersion, String baselineSha256, long baselineSizeBytes,
             String candidateSha256, long candidateSizeBytes, String candidateVersion,
             boolean disabled) {
            this.experimentId = experimentId;
            this.slug = slug;
            this.target = target;
            this.fabricId = fabricId;
            this.manifestVersion = manifestVersion;
            this.baselineSha256 = baselineSha256;
            this.baselineSizeBytes = baselineSizeBytes;
            this.candidateSha256 = candidateSha256;
            this.candidateSizeBytes = candidateSizeBytes;
            this.candidateVersion = candidateVersion;
            this.disabled = disabled;
        }
    }
}
