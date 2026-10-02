package pojlib;

import android.app.Activity;

import com.google.gson.Gson;

import java.io.BufferedOutputStream;
import java.io.File;
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
import java.util.Locale;

import pojlib.util.Constants;
import pojlib.util.Logger;
import pojlib.util.json.MinecraftInstances;
import pojlib.util.json.ModsJson;
import pojlib.util.json.ProjectInfo;

/**
 * Disabled-by-default, fail-closed gate for one Vivecraft core JAR launch.
 * The persistent request never grants permission by itself: only a Permit held
 * in this Android process can make the unattended stack verifier accept a
 * candidate hash in place of the APK-bundled baseline.
 */
final class VivecraftCoreCanaryGate {
    // v9 deliberately uses a new state directory. The v8 namespace contains
    // the immutable RC7 baseline and must never be reused for RC8.
    static final String HARNESS_ID = "questcraft-vivecraft-core-canary-v9";
    static final String EXPECTED_PACKAGE = "com.qcxr.qcxr.canary262";
    static final String PROFILE = "26.2";
    static final String VERSION = "26.2";
    static final String TARGET = "mods/Vivecraft.jar";
    static final String STATE_RELATIVE = ".questcraft/" + HARNESS_ID;
    static final String EXPECTED_FABRIC_ID = "vivecraft";
    static final String EXPECTED_BASELINE_FABRIC_VERSION =
            "26.2-1.3.15+qc.v71.rc8-mining";
    static final String EXPECTED_MINECRAFT_DEPENDENCY = "26.2.x";
    static final String EXPECTED_JAVA_DEPENDENCY = ">=25";
    static final String BASELINE_SHA256 =
            "addb01fa168033c42f97c615daf97cbb927b9e94400606eef27cfbe930015eab";

    private static volatile VivecraftCoreCanaryTransaction.Permit processPermit;
    private static boolean processCopyBatchModeClaimed;

    private VivecraftCoreCanaryGate() {
    }

    static boolean prepare(Activity activity, MinecraftInstances.Instance instance) {
        if(activity == null) {
            return true;
        }
        // Package authorization must happen before inspecting the instance,
        // resolving its game directory, probing markers, or touching a
        // process-local Permit. Personal is a literal no-op for this Lab gate.
        if(!EXPECTED_PACKAGE.equals(activity.getPackageName())) {
            return true;
        }
        if(instance == null || !PROFILE.equals(instance.instanceName) ||
                !VERSION.equals(instance.versionName) || instance.gameDir == null) {
            return true;
        }

        Path gameDirectory = Paths.get(instance.gameDir).toAbsolutePath().normalize();
        Path stateDirectory = gameDirectory.resolve(STATE_RELATIVE).normalize();
        Path marker = stateDirectory.resolve("request.json");
        // A launcher process may return from one JVM and start another. Restore
        // this target before consuming a new request; VEQ performs the same
        // operation for its independent target later in prelaunch.
        if(hasProcessPermit() && !abortPromotedCandidate()) {
            Logger.getInstance().appendToLog(
                    "Vivecraft core canary: prior process-local candidate could not be restored");
            return false;
        }
        if(!Files.exists(marker, LinkOption.NOFOLLOW_LINKS)) {
            return true;
        }

        try {
            validateGameDirectory(gameDirectory, stateDirectory);
            BaselineSpec baseline = loadBaselineSpec(activity);
            if(!TARGET.equals(baseline.target)) {
                throw new IOException("unexpected managed Vivecraft target");
            }
            VivecraftCoreCanaryTransaction.Layout layout =
                    new VivecraftCoreCanaryTransaction.Layout(stateDirectory,
                            gameDirectory.resolve(TARGET).normalize());
            materializeBaseline(activity, layout, baseline);
            String otherModsFingerprint = VivecraftCoreCanaryTransaction.fingerprintOtherMods(
                    gameDirectory.resolve("mods"), layout.target,
                    gameDirectory.resolve(VeqCanaryGate.TARGET).normalize());
            VivecraftCoreCanaryTransaction.Contract contract =
                    new VivecraftCoreCanaryTransaction.Contract(
                            HARNESS_ID, EXPECTED_PACKAGE, PROFILE, TARGET,
                            baseline.sha256, baseline.sizeBytes, otherModsFingerprint,
                            System.currentTimeMillis());
            VivecraftCoreCanaryTransaction.Result result =
                    VivecraftCoreCanaryTransaction.execute(layout, contract,
                            VivecraftCoreCanaryTransaction.NO_FAULTS);
            if(result.outcome == VivecraftCoreCanaryTransaction.Outcome.PROMOTED) {
                publishProcessPermit(result.permit);
                Logger.getInstance().appendToLog(
                        "Vivecraft core canary: one process-local launch permitted");
                return true;
            }
            clearProcessPermit();
            if(result.mayLaunch()) {
                Logger.getInstance().appendToLog(
                        "Vivecraft core canary: baseline retained (" + result.detail + ")");
                return true;
            }
            Logger.getInstance().appendToLog(
                    "Vivecraft core canary: launch aborted safely (" + result.detail + ")");
            return false;
        } catch(IOException | RuntimeException failure) {
            clearProcessPermit();
            Logger.getInstance().appendToLog(
                    "Vivecraft core canary: prelaunch rejected safely (" +
                            failure.getClass().getSimpleName() + ")");
            return false;
        }
    }

    /**
     * Claims the fixed JVM mode for the single launch authorized by the current Permit.
     * Any missing, repeated, malformed, cross-package, cross-profile, or changed-stack
     * request resolves to OFF. The claim is consumed before filesystem validation so a
     * failed attempt cannot be retried as ON in this Android process.
     */
    static synchronized String takeOpenXrCopyBatchMode(
            Activity activity, MinecraftInstances.Instance instance) {
        VivecraftCoreCanaryTransaction.Permit permit = processPermit;
        if(permit == null || processCopyBatchModeClaimed) {
            return VivecraftCoreCanaryTransaction.OPENXR_COPY_BATCH_OFF;
        }
        processCopyBatchModeClaimed = true;
        if(activity == null || instance == null ||
                !EXPECTED_PACKAGE.equals(activity.getPackageName()) ||
                !PROFILE.equals(instance.instanceName) || !VERSION.equals(instance.versionName) ||
                instance.gameDir == null) {
            return VivecraftCoreCanaryTransaction.OPENXR_COPY_BATCH_OFF;
        }
        try {
            Path gameDirectory = Paths.get(instance.gameDir).toAbsolutePath().normalize();
            Path stateDirectory = gameDirectory.resolve(STATE_RELATIVE).normalize();
            validateGameDirectory(gameDirectory, stateDirectory);
            Path target = gameDirectory.resolve(TARGET).normalize();
            long size = Files.size(target);
            String hash = VivecraftCoreCanaryTransaction.sha256(target);
            String fingerprint = VivecraftCoreCanaryTransaction.fingerprintOtherMods(
                    target.getParent(), target,
                    target.getParent().resolve("Vivecraft-Essentials-Quest.jar"));
            if(!VivecraftCoreCanaryTransaction.permitMatches(
                    permit, target, hash, size, fingerprint)) {
                return VivecraftCoreCanaryTransaction.OPENXR_COPY_BATCH_OFF;
            }
            return VivecraftCoreCanaryTransaction.OPENXR_COPY_BATCH_ON.equals(
                    permit.openXrCopyBatchMode)
                    ? VivecraftCoreCanaryTransaction.OPENXR_COPY_BATCH_ON
                    : VivecraftCoreCanaryTransaction.OPENXR_COPY_BATCH_OFF;
        } catch(IOException | RuntimeException ignored) {
            return VivecraftCoreCanaryTransaction.OPENXR_COPY_BATCH_OFF;
        }
    }

    static boolean verifyVivecraftArtifact(
            MinecraftInstances.Instance instance, ProjectInfo project, File artifact) {
        VivecraftCoreCanaryTransaction.Permit permit = processPermit;
        if(permit == null || instance == null || project == null || artifact == null ||
                !"Vivecraft".equals(project.slug) || !PROFILE.equals(instance.instanceName) ||
                !VERSION.equals(instance.versionName) || instance.gameDir == null) {
            return false;
        }
        try {
            Path target = artifact.toPath().toAbsolutePath().normalize();
            long size = Files.size(target);
            String hash = VivecraftCoreCanaryTransaction.sha256(target);
            String fingerprint = VivecraftCoreCanaryTransaction.fingerprintOtherMods(
                    target.getParent(), target,
                    target.getParent().resolve("Vivecraft-Essentials-Quest.jar"));
            return VivecraftCoreCanaryTransaction.permitMatches(
                    permit, target, hash, size, fingerprint);
        } catch(IOException | RuntimeException ignored) {
            return false;
        }
    }

    static synchronized boolean hasProcessPermit() {
        return processPermit != null;
    }

    static boolean abortPromotedCandidate() {
        VivecraftCoreCanaryTransaction.Permit permit;
        synchronized(VivecraftCoreCanaryGate.class) {
            permit = processPermit;
            processPermit = null;
            processCopyBatchModeClaimed = false;
        }
        boolean restored = VivecraftCoreCanaryTransaction.restoreAfterFailure(permit);
        Logger.getInstance().appendToLog(restored
                ? "Vivecraft core canary: baseline restored after verification failure"
                : "Vivecraft core canary: baseline restoration failed; launch remains aborted");
        return restored;
    }

    private static synchronized void publishProcessPermit(
            VivecraftCoreCanaryTransaction.Permit permit) {
        processPermit = permit;
        processCopyBatchModeClaimed = false;
    }

    private static synchronized void clearProcessPermit() {
        processPermit = null;
        processCopyBatchModeClaimed = false;
    }

    private static void validateGameDirectory(Path gameDirectory, Path stateDirectory) throws IOException {
        if(Constants.USER_HOME == null) {
            throw new IOException("launcher home is unavailable");
        }
        Path expected = Paths.get(Constants.USER_HOME).toAbsolutePath().normalize()
                .resolve("instances").resolve(PROFILE).normalize();
        if(!stateDirectory.startsWith(gameDirectory) ||
                Files.isSymbolicLink(gameDirectory) || Files.isSymbolicLink(stateDirectory) ||
                !Files.isDirectory(gameDirectory, LinkOption.NOFOLLOW_LINKS) ||
                !Files.isDirectory(stateDirectory, LinkOption.NOFOLLOW_LINKS)) {
            throw new IOException("canary path is outside the exact profile");
        }
        Path realGame = gameDirectory.toRealPath(LinkOption.NOFOLLOW_LINKS);
        Path realExpected = expected.toRealPath(LinkOption.NOFOLLOW_LINKS);
        Path realState = stateDirectory.toRealPath(LinkOption.NOFOLLOW_LINKS);
        if(!realGame.equals(realExpected) || !realState.startsWith(realGame)) {
            throw new IOException("canary state directory escaped the profile");
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
                if(version == null || !VERSION.equals(version.name) || version.coreMods == null) {
                    continue;
                }
                for(ProjectInfo project : version.coreMods) {
                    if(project != null && "Vivecraft".equals(project.slug)) {
                        if(match != null) {
                            throw new IOException("bundled manifest has duplicate Vivecraft entries");
                        }
                        match = project;
                    }
                }
            }
            if(match == null || match.fileName != null ||
                    !EXPECTED_BASELINE_FABRIC_VERSION.equals(match.version) ||
                    match.sha256 == null || !BASELINE_SHA256.equals(
                            match.sha256.toLowerCase(Locale.ROOT)) || match.download_link == null ||
                    !match.download_link.startsWith("asset://mods/") ||
                    !match.download_link.endsWith(".bin")) {
                throw new IOException("bundled Vivecraft lock is invalid");
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
                    throw new IOException("bundled Vivecraft exceeds canary size limit");
                }
            }
        }
        if(total <= 0) {
            throw new IOException("bundled Vivecraft is empty");
        }
        return total;
    }

    private static void materializeBaseline(
            Activity activity, VivecraftCoreCanaryTransaction.Layout layout,
            BaselineSpec baseline) throws IOException {
        if(Files.exists(layout.baselineSource, LinkOption.NOFOLLOW_LINKS)) {
            if(Files.isSymbolicLink(layout.baselineSource) ||
                    Files.size(layout.baselineSource) != baseline.sizeBytes ||
                    !baseline.sha256.equals(VivecraftCoreCanaryTransaction.sha256(layout.baselineSource))) {
                throw new IOException("existing baseline source does not match the APK");
            }
            return;
        }

        Path stage = layout.stateDirectory.resolve("baseline.tmp");
        if(Files.isSymbolicLink(stage)) {
            throw new IOException("baseline stage is a symbolic link");
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
                    throw new IOException("bundled baseline changed while staging");
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
            throw new IOException("staged baseline does not match the APK lock");
        }
        try {
            Files.move(stage, layout.baselineSource,
                    StandardCopyOption.ATOMIC_MOVE, StandardCopyOption.REPLACE_EXISTING);
        } catch(AtomicMoveNotSupportedException e) {
            Files.deleteIfExists(stage);
            throw new IOException("atomic baseline staging is required", e);
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
