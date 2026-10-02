package pojlib;

import android.app.Activity;

import com.google.gson.Gson;

import java.io.BufferedOutputStream;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.InputStreamReader;
import java.nio.charset.StandardCharsets;
import java.nio.file.AtomicMoveNotSupportedException;
import java.nio.file.Files;
import java.nio.file.LinkOption;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.nio.file.StandardCopyOption;
import java.util.Collections;
import java.util.Locale;

import pojlib.util.Constants;
import pojlib.util.Logger;
import pojlib.util.json.MinecraftInstances;
import pojlib.util.json.ModsJson;
import pojlib.util.json.ProjectInfo;

/**
 * One-shot, fail-closed VEQ v71 gate for the isolated 26.2 Lab package.
 *
 * <p>The host must explicitly bind every deployment to an independently supplied SHA-256.
 * Runtime then binds the marker's exact hash, size and Fabric metadata to a process-local
 * Permit. This Lab-only gate intentionally does not bake not-yet-built v70 candidate hashes
 * into the APK.</p>
 */
final class VeqCanaryGate {
    // v5 keeps the RC8-integrated VEQ baseline isolated from immutable v1-v4 state.
    static final String HARNESS_ID = "questcraft-veq-v71-canary-v5";
    static final String EXPECTED_PACKAGE = "com.qcxr.qcxr.canary262";
    static final String PROFILE = "26.2";
    static final String VERSION = "26.2";
    static final String TARGET = "mods/Vivecraft-Essentials-Quest.jar";
    static final String STATE_RELATIVE = ".questcraft/" + HARNESS_ID;
    static final String EXPECTED_FABRIC_ID = "vivecraft_essentials_quest";
    static final String EXPECTED_FABRIC_VERSION = "0.7.0-v71.rc6";
    static final String EXPECTED_MINECRAFT_DEPENDENCY = "26.2";
    static final String EXPECTED_JAVA_DEPENDENCY = ">=25";
    static final String BASELINE_SHA256 =
            "ff7f6fcfda21895764b69f3316ce7e9ebd8d890df675c1e8007835b3814573f9";
    static final String REJECTED_CANDIDATE_SHA256 =
            "35b71c9c432b42af067d65beeb1e966c2242181d085449c411b230f568800095";

    private static volatile VivecraftCoreCanaryTransaction.Permit processPermit;

    private VeqCanaryGate() {
    }

    static boolean prepare(Activity activity, MinecraftInstances.Instance instance) {
        if(activity == null || instance == null || !PROFILE.equals(instance.instanceName) ||
                !VERSION.equals(instance.versionName) || instance.gameDir == null) {
            return true;
        }
        // A non-Lab build must be an exact no-op: do not inspect its profile,
        // marker, or process permit, and never let Lab state block Stable Play.
        if(!EXPECTED_PACKAGE.equals(activity.getPackageName())) {
            return true;
        }

        Path gameDirectory = Paths.get(instance.gameDir).toAbsolutePath().normalize();
        Path stateDirectory = gameDirectory.resolve(STATE_RELATIVE).normalize();
        Path marker = stateDirectory.resolve("request.json");
        // A second Play in the same launcher process is the next prelaunch too.
        // Restore the one-shot candidate before considering another marker.
        if(processPermit != null && !abortPromotedCandidate()) {
            Logger.getInstance().appendToLog(
                    "VEQ canary: prior process-local candidate could not be restored");
            return false;
        }
        if(!Files.exists(marker, LinkOption.NOFOLLOW_LINKS)) {
            return true;
        }
        try {
            validateGameDirectory(gameDirectory, stateDirectory);
            BaselineSpec baseline = loadBaselineSpec(activity);
            if(!TARGET.equals(baseline.target) || !BASELINE_SHA256.equals(baseline.sha256)) {
                throw new IOException("unexpected managed VEQ baseline");
            }
            VivecraftCoreCanaryTransaction.Layout layout =
                    new VivecraftCoreCanaryTransaction.Layout(stateDirectory,
                            gameDirectory.resolve(TARGET).normalize());
            materializeBaseline(activity, layout, baseline);
            String otherModsFingerprint = VivecraftCoreCanaryTransaction.fingerprintOtherMods(
                    gameDirectory.resolve("mods"), layout.target,
                    gameDirectory.resolve(VivecraftCoreCanaryGate.TARGET).normalize());
            VivecraftCoreCanaryTransaction.Marker requested;
            try {
                requested = VivecraftCoreCanaryTransaction.readMarker(layout.marker);
            } catch(IOException | RuntimeException invalid) {
                // Let execute() quarantine the malformed marker while using an
                // empty candidate policy for this attempt.
                requested = null;
            }
            VivecraftCoreCanaryTransaction.Contract contract =
                    new VivecraftCoreCanaryTransaction.Contract(
                            HARNESS_ID, EXPECTED_PACKAGE, PROFILE, TARGET,
                            baseline.sha256, baseline.sizeBytes, otherModsFingerprint,
                            System.currentTimeMillis(), EXPECTED_FABRIC_ID,
                            EXPECTED_FABRIC_VERSION, EXPECTED_MINECRAFT_DEPENDENCY,
                            EXPECTED_JAVA_DEPENDENCY,
                            requested != null && requested.candidateSha256 != null &&
                                    requested.candidateSha256.matches("^[0-9a-f]{64}$") &&
                                    !REJECTED_CANDIDATE_SHA256.equals(requested.candidateSha256)
                                    ? Collections.singleton(requested.candidateSha256)
                                    : Collections.emptySet());
            VivecraftCoreCanaryTransaction.Result result =
                    VivecraftCoreCanaryTransaction.execute(layout, contract,
                            VivecraftCoreCanaryTransaction.NO_FAULTS);
            if(result.outcome == VivecraftCoreCanaryTransaction.Outcome.PROMOTED) {
                processPermit = result.permit;
                Logger.getInstance().appendToLog(
                        "VEQ canary: v71 candidate permitted for one process");
                return true;
            }
            processPermit = null;
            if(result.mayLaunch()) {
                Logger.getInstance().appendToLog(
                        "VEQ canary: baseline retained (" + result.detail + ")");
                return true;
            }
            Logger.getInstance().appendToLog(
                    "VEQ canary: launch aborted safely (" + result.detail + ")");
            return false;
        } catch(IOException | RuntimeException failure) {
            processPermit = null;
            Logger.getInstance().appendToLog(
                    "VEQ canary: prelaunch rejected safely (" +
                            failure.getClass().getSimpleName() + ")");
            return false;
        }
    }

    static boolean verifyVeqArtifact(
            MinecraftInstances.Instance instance, ProjectInfo project, java.io.File artifact) {
        VivecraftCoreCanaryTransaction.Permit permit = processPermit;
        if(permit == null || instance == null || project == null || artifact == null ||
                !"Vivecraft-Essentials-Quest".equals(project.slug) ||
                !PROFILE.equals(instance.instanceName) || !VERSION.equals(instance.versionName) ||
                instance.gameDir == null) {
            return false;
        }
        try {
            Path target = artifact.toPath().toAbsolutePath().normalize();
            long size = Files.size(target);
            String hash = VivecraftCoreCanaryTransaction.sha256(target);
            String fingerprint = VivecraftCoreCanaryTransaction.fingerprintOtherMods(
                    target.getParent(), target,
                    target.getParent().resolve("Vivecraft.jar"));
            return VivecraftCoreCanaryTransaction.permitMatches(
                    permit, target, hash, size, fingerprint);
        } catch(IOException | RuntimeException ignored) {
            return false;
        }
    }

    static boolean hasProcessPermit() {
        return processPermit != null;
    }

    static boolean abortPromotedCandidate() {
        VivecraftCoreCanaryTransaction.Permit permit = processPermit;
        processPermit = null;
        boolean restored = VivecraftCoreCanaryTransaction.restoreAfterFailure(permit);
        Logger.getInstance().appendToLog(restored
                ? "VEQ canary: baseline restored after verification failure"
                : "VEQ canary: baseline restoration failed; launch remains aborted");
        return restored;
    }

    private static void validateGameDirectory(Path gameDirectory, Path stateDirectory)
            throws IOException {
        if(Constants.USER_HOME == null) {
            throw new IOException("launcher home is unavailable");
        }
        Path expected = Paths.get(Constants.USER_HOME).toAbsolutePath().normalize()
                .resolve("instances").resolve(PROFILE).normalize();
        if(!stateDirectory.startsWith(gameDirectory) ||
                Files.isSymbolicLink(gameDirectory) || Files.isSymbolicLink(stateDirectory) ||
                !Files.isDirectory(gameDirectory, LinkOption.NOFOLLOW_LINKS) ||
                !Files.isDirectory(stateDirectory, LinkOption.NOFOLLOW_LINKS)) {
            throw new IOException("VEQ canary path is outside the exact profile");
        }
        Path realGame = gameDirectory.toRealPath(LinkOption.NOFOLLOW_LINKS);
        Path realExpected = expected.toRealPath(LinkOption.NOFOLLOW_LINKS);
        Path realState = stateDirectory.toRealPath(LinkOption.NOFOLLOW_LINKS);
        if(!realGame.equals(realExpected) || !realState.startsWith(realGame)) {
            throw new IOException("VEQ canary state directory escaped the profile");
        }
    }

    private static BaselineSpec loadBaselineSpec(Activity activity) throws IOException {
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
                    if(project != null && "Vivecraft-Essentials-Quest".equals(project.slug)) {
                        if(match != null) {
                            throw new IOException("bundled manifest has duplicate VEQ entries");
                        }
                        match = project;
                    }
                }
            }
            if(match == null || match.fileName != null ||
                    !EXPECTED_FABRIC_VERSION.equals(match.version) ||
                    match.sha256 == null || !BASELINE_SHA256.equals(
                            match.sha256.toLowerCase(Locale.ROOT)) ||
                    !"asset://mods/vivecraft-essentials-quest.bin".equals(match.download_link)) {
                throw new IOException("bundled VEQ lock is invalid");
            }
            String asset = match.download_link.substring("asset://".length());
            long size = assetSize(activity, asset);
            return new BaselineSpec(TARGET, asset, BASELINE_SHA256, size);
        } catch(RuntimeException e) {
            throw new IOException("could not parse bundled managed manifest", e);
        }
    }

    private static long assetSize(Activity activity, String asset) throws IOException {
        long total = 0;
        try(InputStream input = activity.getAssets().open(asset)) {
            byte[] buffer = new byte[64 * 1024];
            int read;
            while((read = input.read(buffer)) != -1) {
                total += read;
                if(total > VivecraftCoreCanaryTransaction.MAX_CANDIDATE_BYTES) {
                    throw new IOException("bundled VEQ exceeds canary size limit");
                }
            }
        }
        if(total <= 0) {
            throw new IOException("bundled VEQ is empty");
        }
        return total;
    }

    private static void materializeBaseline(
            Activity activity, VivecraftCoreCanaryTransaction.Layout layout,
            BaselineSpec baseline) throws IOException {
        if(Files.exists(layout.baselineSource, LinkOption.NOFOLLOW_LINKS)) {
            if(Files.isSymbolicLink(layout.baselineSource) ||
                    Files.size(layout.baselineSource) != baseline.sizeBytes ||
                    !baseline.sha256.equals(
                            VivecraftCoreCanaryTransaction.sha256(layout.baselineSource))) {
                throw new IOException("existing VEQ baseline source does not match the APK");
            }
            return;
        }

        Path stage = layout.stateDirectory.resolve("baseline.tmp");
        if(Files.isSymbolicLink(stage)) {
            throw new IOException("VEQ baseline stage is a symbolic link");
        }
        Files.deleteIfExists(stage);
        try(InputStream input = activity.getAssets().open(baseline.assetPath);
                FileOutputStream file = new FileOutputStream(stage.toFile());
                BufferedOutputStream output = new BufferedOutputStream(file)) {
            byte[] buffer = new byte[64 * 1024];
            long total = 0;
            int read;
            while((read = input.read(buffer)) != -1) {
                total += read;
                if(total > baseline.sizeBytes) {
                    throw new IOException("bundled VEQ baseline changed while staging");
                }
                output.write(buffer, 0, read);
            }
            output.flush();
            file.getFD().sync();
        } catch(IOException failure) {
            Files.deleteIfExists(stage);
            throw failure;
        }
        if(Files.size(stage) != baseline.sizeBytes ||
                !baseline.sha256.equals(VivecraftCoreCanaryTransaction.sha256(stage))) {
            Files.deleteIfExists(stage);
            throw new IOException("staged VEQ baseline does not match the APK lock");
        }
        try {
            Files.move(stage, layout.baselineSource,
                    StandardCopyOption.ATOMIC_MOVE, StandardCopyOption.REPLACE_EXISTING);
        } catch(AtomicMoveNotSupportedException e) {
            Files.deleteIfExists(stage);
            throw new IOException("atomic VEQ baseline staging is required", e);
        }
    }

    private static final class BaselineSpec {
        final String target;
        final String assetPath;
        final String sha256;
        final long sizeBytes;

        BaselineSpec(String target, String assetPath, String sha256, long sizeBytes) {
            this.target = target;
            this.assetPath = assetPath;
            this.sha256 = sha256;
            this.sizeBytes = sizeBytes;
        }
    }
}
