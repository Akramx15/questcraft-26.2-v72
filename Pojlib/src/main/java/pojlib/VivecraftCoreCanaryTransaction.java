package pojlib;

import com.google.gson.stream.JsonReader;
import com.google.gson.stream.JsonToken;
import com.google.gson.stream.JsonWriter;

import java.io.BufferedInputStream;
import java.io.BufferedOutputStream;
import java.io.ByteArrayInputStream;
import java.io.ByteArrayOutputStream;
import java.io.EOFException;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.InputStreamReader;
import java.io.OutputStreamWriter;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.channels.FileChannel;
import java.nio.channels.FileLock;
import java.nio.channels.OverlappingFileLockException;
import java.nio.charset.CharacterCodingException;
import java.nio.charset.CodingErrorAction;
import java.nio.charset.StandardCharsets;
import java.nio.file.AtomicMoveNotSupportedException;
import java.nio.file.DirectoryStream;
import java.nio.file.Files;
import java.nio.file.LinkOption;
import java.nio.file.Path;
import java.nio.file.StandardCopyOption;
import java.nio.file.StandardOpenOption;
import java.security.MessageDigest;
import java.security.NoSuchAlgorithmException;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Collections;
import java.util.HashSet;
import java.util.List;
import java.util.Locale;
import java.util.Set;
import java.util.zip.ZipEntry;
import java.util.zip.ZipFile;

/**
 * Pure-Java transaction core for the Vivecraft JAR canary gate.
 *
 * <p>This class deliberately has package visibility. The launcher-facing API
 * remains unchanged, and Host tests can exercise every filesystem transition
 * without loading Android classes or contacting a device.</p>
 */
final class VivecraftCoreCanaryTransaction {
    static final String ABSENT_DEPENDENCY = "<absent>";
    static final int SCHEMA_VERSION = 2;
    static final long MAX_CANDIDATE_BYTES = 16L * 1024L * 1024L;
    static final long MAX_ARCHIVE_UNCOMPRESSED_BYTES = 64L * 1024L * 1024L;
    static final int MAX_ARCHIVE_ENTRIES = 4096;
    static final int MAX_FABRIC_METADATA_BYTES = 128 * 1024;
    static final int MAX_MARKER_BYTES = 16 * 1024;
    static final long MAX_ARM_TTL_MS = 30L * 60L * 1000L;

    static final String STATE_ARMED = "armed";
    static final String STATE_ATTEMPTING = "attempting";
    static final String STATE_CONSUMED = "consumed";
    static final String STATE_EXPIRED = "expired";
    static final String OPENXR_COPY_BATCH_OFF = "OFF";
    static final String OPENXR_COPY_BATCH_ON = "ON";

    private static final Set<String> MARKER_FIELDS = Collections.unmodifiableSet(new HashSet<>(Arrays.asList(
            "schemaVersion", "harnessId", "state", "packageName", "profile", "target", "runId",
            "baselineSha256", "baselineSizeBytes", "candidateSha256", "candidateSizeBytes",
            "fabricId", "fabricVersion", "minecraftDependency", "javaDependency",
            "otherModsFingerprintSha256", "openXrCopyBatchMode", "expiresAtEpochMs",
            "maxLaunches")));

    enum Outcome {
        BASELINE,
        PROMOTED,
        TERMINAL_RESTORED,
        INVALID_QUARANTINED,
        BUSY,
        FAILED
    }

    enum Stage {
        VALIDATED,
        ATTEMPTING_COMMITTED,
        CANDIDATE_PROMOTED,
        PROMOTED_VERIFIED,
        CONSUMED_COMMITTED,
        PERMIT_PUBLISHED
    }

    interface FaultInjector {
        void after(Stage stage) throws IOException;
    }

    static final FaultInjector NO_FAULTS = stage -> { };

    static final class Contract {
        final String harnessId;
        final String packageName;
        final String profile;
        final String target;
        final String baselineSha256;
        final long baselineSizeBytes;
        final String otherModsFingerprintSha256;
        final long nowEpochMs;
        final String fabricId;
        final String fabricVersion;
        final String minecraftDependency;
        final String javaDependency;
        final boolean candidateShaAllowlistEnforced;
        final Set<String> allowedCandidateSha256s;

        Contract(String harnessId, String packageName, String profile, String target,
                 String baselineSha256, long baselineSizeBytes,
                 String otherModsFingerprintSha256, long nowEpochMs) {
            this(harnessId, packageName, profile, target, baselineSha256, baselineSizeBytes,
                    otherModsFingerprintSha256, nowEpochMs,
                    "vivecraft", "26.2.x", ">=25", null);
        }

        Contract(String harnessId, String packageName, String profile, String target,
                 String baselineSha256, long baselineSizeBytes,
                 String otherModsFingerprintSha256, long nowEpochMs,
                 String fabricId, String minecraftDependency, String javaDependency,
                 Set<String> allowedCandidateSha256s) {
            this(harnessId, packageName, profile, target, baselineSha256, baselineSizeBytes,
                    otherModsFingerprintSha256, nowEpochMs, fabricId, null,
                    minecraftDependency, javaDependency, allowedCandidateSha256s);
        }

        Contract(String harnessId, String packageName, String profile, String target,
                 String baselineSha256, long baselineSizeBytes,
                 String otherModsFingerprintSha256, long nowEpochMs,
                 String fabricId, String fabricVersion, String minecraftDependency,
                 String javaDependency, Set<String> allowedCandidateSha256s) {
            this.harnessId = harnessId;
            this.packageName = packageName;
            this.profile = profile;
            this.target = target;
            this.baselineSha256 = normalizedSha256(baselineSha256);
            this.baselineSizeBytes = baselineSizeBytes;
            this.otherModsFingerprintSha256 = normalizedSha256(otherModsFingerprintSha256);
            this.nowEpochMs = nowEpochMs;
            if(!nonBlank(fabricId) || !nonBlank(minecraftDependency) || !nonBlank(javaDependency)) {
                throw new IllegalArgumentException("Invalid Fabric metadata contract");
            }
            if(fabricVersion != null && !nonBlank(fabricVersion)) {
                throw new IllegalArgumentException("Invalid Fabric version contract");
            }
            this.fabricId = fabricId;
            this.fabricVersion = fabricVersion;
            this.minecraftDependency = minecraftDependency;
            this.javaDependency = javaDependency;
            this.candidateShaAllowlistEnforced = allowedCandidateSha256s != null;
            Set<String> normalizedCandidates = new HashSet<>();
            if(allowedCandidateSha256s != null) {
                for(String candidate : allowedCandidateSha256s) {
                    normalizedCandidates.add(normalizedSha256(candidate));
                }
            }
            this.allowedCandidateSha256s = Collections.unmodifiableSet(normalizedCandidates);
        }
    }

    static final class Layout {
        final Path stateDirectory;
        final Path marker;
        final Path rejectedMarker;
        final Path lock;
        final Path target;
        final Path baselineSource;

        Layout(Path stateDirectory, Path target) {
            this.stateDirectory = stateDirectory;
            this.marker = stateDirectory.resolve("request.json");
            this.rejectedMarker = stateDirectory.resolve("request.rejected.json");
            this.lock = stateDirectory.resolve("prelaunch.lock");
            this.target = target;
            this.baselineSource = stateDirectory.resolve("baseline.jar");
        }

        Path candidate(String runId) {
            return stateDirectory.resolve("candidate-" + runId + ".jar");
        }

        Path markerStage(String runId) {
            return stateDirectory.resolve("request-" + runId + ".tmp");
        }

        Path baselineRestoreStage(String runId) {
            return target.resolveSibling(".vivecraft-baseline-" + runId + ".tmp");
        }
    }

    static final class Marker {
        int schemaVersion;
        String harnessId;
        String state;
        String packageName;
        String profile;
        String target;
        String runId;
        String baselineSha256;
        long baselineSizeBytes;
        String candidateSha256;
        long candidateSizeBytes;
        String fabricId;
        String fabricVersion;
        String minecraftDependency;
        String javaDependency;
        String otherModsFingerprintSha256;
        String openXrCopyBatchMode;
        long expiresAtEpochMs;
        int maxLaunches;

        Marker withState(String replacement) {
            Marker copy = new Marker();
            copy.schemaVersion = schemaVersion;
            copy.harnessId = harnessId;
            copy.state = replacement;
            copy.packageName = packageName;
            copy.profile = profile;
            copy.target = target;
            copy.runId = runId;
            copy.baselineSha256 = baselineSha256;
            copy.baselineSizeBytes = baselineSizeBytes;
            copy.candidateSha256 = candidateSha256;
            copy.candidateSizeBytes = candidateSizeBytes;
            copy.fabricId = fabricId;
            copy.fabricVersion = fabricVersion;
            copy.minecraftDependency = minecraftDependency;
            copy.javaDependency = javaDependency;
            copy.otherModsFingerprintSha256 = otherModsFingerprintSha256;
            copy.openXrCopyBatchMode = openXrCopyBatchMode;
            copy.expiresAtEpochMs = expiresAtEpochMs;
            copy.maxLaunches = maxLaunches;
            return copy;
        }
    }

    static final class Permit {
        final String runId;
        final Path target;
        final Path baselineSource;
        final Path lock;
        final String baselineSha256;
        final long baselineSizeBytes;
        final String candidateSha256;
        final long candidateSizeBytes;
        final String otherModsFingerprintSha256;
        final String openXrCopyBatchMode;

        Permit(Marker marker, Layout layout) {
            this.runId = marker.runId;
            this.target = layout.target;
            this.baselineSource = layout.baselineSource;
            this.lock = layout.lock;
            this.baselineSha256 = marker.baselineSha256;
            this.baselineSizeBytes = marker.baselineSizeBytes;
            this.candidateSha256 = marker.candidateSha256;
            this.candidateSizeBytes = marker.candidateSizeBytes;
            this.otherModsFingerprintSha256 = marker.otherModsFingerprintSha256;
            this.openXrCopyBatchMode = marker.openXrCopyBatchMode;
        }
    }

    static final class Result {
        final Outcome outcome;
        final Permit permit;
        final String detail;

        Result(Outcome outcome, Permit permit, String detail) {
            this.outcome = outcome;
            this.permit = permit;
            this.detail = detail;
        }

        boolean mayLaunch() {
            return outcome != Outcome.BUSY && outcome != Outcome.FAILED;
        }
    }

    private VivecraftCoreCanaryTransaction() {
    }

    static Result execute(Layout layout, Contract contract, FaultInjector faults) {
        if(!Files.exists(layout.marker, LinkOption.NOFOLLOW_LINKS)) {
            return new Result(Outcome.BASELINE, null, "no-marker");
        }
        if(Files.isSymbolicLink(layout.stateDirectory) || Files.isSymbolicLink(layout.marker) ||
                Files.isSymbolicLink(layout.lock) ||
                Files.isSymbolicLink(layout.target) || Files.isSymbolicLink(layout.baselineSource)) {
            return new Result(Outcome.FAILED, null, "symlink-rejected");
        }

        try(FileChannel channel = FileChannel.open(layout.lock,
                    StandardOpenOption.CREATE, StandardOpenOption.WRITE);
                FileLock ignored = tryLock(channel)) {
            if(ignored == null) {
                return new Result(Outcome.BUSY, null, "prelaunch-lock-busy");
            }
            return executeLocked(layout, contract, faults == null ? NO_FAULTS : faults);
        } catch(OverlappingFileLockException e) {
            return new Result(Outcome.BUSY, null, "prelaunch-lock-overlap");
        } catch(IOException | RuntimeException e) {
            return new Result(Outcome.FAILED, null, e.getClass().getSimpleName());
        }
    }

    private static FileLock tryLock(FileChannel channel) throws IOException {
        try {
            return channel.tryLock();
        } catch(OverlappingFileLockException e) {
            return null;
        }
    }

    private static Result executeLocked(Layout layout, Contract contract, FaultInjector faults)
            throws IOException {
        Marker marker;
        try {
            marker = readMarker(layout.marker);
        } catch(IOException | RuntimeException invalid) {
            restoreBaseline(layout, contract, "invalid");
            quarantineMarker(layout);
            return new Result(Outcome.INVALID_QUARANTINED, null, "invalid-marker");
        }

        if(!validIdentity(marker, contract)) {
            restoreBaseline(layout, contract, safeRestoreRunId(marker.runId));
            quarantineMarker(layout);
            return new Result(Outcome.INVALID_QUARANTINED, null, "contract-mismatch");
        }

        if(!STATE_ARMED.equals(marker.state)) {
            restoreBaseline(layout, contract, marker.runId);
            deleteCandidateIfSafe(layout, marker);
            return new Result(Outcome.TERMINAL_RESTORED, null, "terminal-" + marker.state);
        }

        if(marker.expiresAtEpochMs <= contract.nowEpochMs) {
            writeMarkerAtomically(layout, marker.withState(STATE_EXPIRED));
            restoreBaseline(layout, contract, marker.runId);
            deleteCandidateIfSafe(layout, marker);
            return new Result(Outcome.TERMINAL_RESTORED, null, "expired");
        }

        Path candidate = layout.candidate(marker.runId);
        boolean attemptCommitted = false;
        boolean promoted = false;
        try {
            requireRegularFile(candidate, "candidate");
            requireRegularFile(layout.baselineSource, "baseline source");
            requireExactFile(layout.baselineSource, contract.baselineSizeBytes, contract.baselineSha256,
                    "baseline source");
            requireExactFile(layout.target, contract.baselineSizeBytes, contract.baselineSha256,
                    "managed baseline");
            requireExactFile(candidate, marker.candidateSizeBytes, marker.candidateSha256, "candidate");
            inspectCandidateJar(candidate, marker);
            faults.after(Stage.VALIDATED);

            writeMarkerAtomically(layout, marker.withState(STATE_ATTEMPTING));
            attemptCommitted = true;
            faults.after(Stage.ATTEMPTING_COMMITTED);

            atomicMove(candidate, layout.target);
            promoted = true;
            faults.after(Stage.CANDIDATE_PROMOTED);

            requireExactFile(layout.target, marker.candidateSizeBytes, marker.candidateSha256,
                    "promoted candidate");
            faults.after(Stage.PROMOTED_VERIFIED);

            writeMarkerAtomically(layout, marker.withState(STATE_CONSUMED));
            faults.after(Stage.CONSUMED_COMMITTED);

            Permit permit = new Permit(marker, layout);
            faults.after(Stage.PERMIT_PUBLISHED);
            return new Result(Outcome.PROMOTED, permit, "candidate-promoted");
        } catch(IOException | RuntimeException failure) {
            if(attemptCommitted || promoted) {
                try {
                    restoreBaseline(layout, contract, marker.runId);
                    deleteCandidateIfSafe(layout, marker);
                    writeMarkerAtomically(layout, marker.withState(STATE_CONSUMED));
                } catch(IOException restoreFailure) {
                    failure.addSuppressed(restoreFailure);
                }
            } else {
                try {
                    restoreBaseline(layout, contract, marker.runId);
                    deleteCandidateIfSafe(layout, marker);
                    quarantineMarker(layout);
                } catch(IOException quarantineFailure) {
                    failure.addSuppressed(quarantineFailure);
                }
            }
            return new Result(Outcome.FAILED, null, failure.getClass().getSimpleName());
        }
    }

    static boolean restoreAfterFailure(Permit permit) {
        if(permit == null) {
            return true;
        }
        try(FileChannel channel = FileChannel.open(permit.lock,
                    StandardOpenOption.CREATE, StandardOpenOption.WRITE);
                FileLock ignored = tryLock(channel)) {
            if(ignored == null) {
                return false;
            }
            requireRegularFile(permit.baselineSource, "baseline source");
            requireExactFile(permit.baselineSource, permit.baselineSizeBytes,
                    permit.baselineSha256, "baseline source");
            Path stage = permit.target.resolveSibling(".vivecraft-baseline-" + permit.runId + ".tmp");
            if(Files.isSymbolicLink(stage) || Files.isSymbolicLink(permit.target)) {
                return false;
            }
            Files.deleteIfExists(stage);
            try {
                Files.copy(permit.baselineSource, stage);
                requireExactFile(stage, permit.baselineSizeBytes, permit.baselineSha256,
                        "baseline restore stage");
                atomicMove(stage, permit.target);
                requireExactFile(permit.target, permit.baselineSizeBytes, permit.baselineSha256,
                        "restored baseline");
                return true;
            } finally {
                Files.deleteIfExists(stage);
            }
        } catch(IOException | RuntimeException ignored) {
            return false;
        }
    }

    static boolean permitMatches(Permit permit, Path target, String sha256, long sizeBytes,
                                 String otherModsFingerprintSha256) {
        if(permit == null || target == null || sha256 == null || otherModsFingerprintSha256 == null) {
            return false;
        }
        try {
            return Files.isSameFile(permit.target, target) &&
                    permit.candidateSizeBytes == sizeBytes &&
                    permit.candidateSha256.equals(normalizedSha256(sha256)) &&
                    permit.otherModsFingerprintSha256.equals(normalizedSha256(otherModsFingerprintSha256));
        } catch(IOException | IllegalArgumentException e) {
            return false;
        }
    }

    static Marker readMarker(Path path) throws IOException {
        if(Files.isSymbolicLink(path) || !Files.isRegularFile(path, LinkOption.NOFOLLOW_LINKS) ||
                Files.size(path) <= 0 || Files.size(path) > MAX_MARKER_BYTES) {
            throw new IOException("Marker is not a bounded regular file");
        }
        try(InputStreamReader input = new InputStreamReader(
                    new BufferedInputStream(new FileInputStream(path.toFile())), StandardCharsets.UTF_8);
                JsonReader reader = new JsonReader(input)) {
            reader.setLenient(false);
            Marker marker = new Marker();
            Set<String> seen = new HashSet<>();
            reader.beginObject();
            while(reader.hasNext()) {
                String name = reader.nextName();
                if(!MARKER_FIELDS.contains(name) || !seen.add(name)) {
                    throw new IOException("Unknown or duplicate marker field");
                }
                switch(name) {
                    case "schemaVersion": marker.schemaVersion = exactInt(reader); break;
                    case "harnessId": marker.harnessId = requiredString(reader); break;
                    case "state": marker.state = requiredString(reader); break;
                    case "packageName": marker.packageName = requiredString(reader); break;
                    case "profile": marker.profile = requiredString(reader); break;
                    case "target": marker.target = requiredString(reader); break;
                    case "runId": marker.runId = requiredString(reader); break;
                    case "baselineSha256": marker.baselineSha256 = requiredString(reader); break;
                    case "baselineSizeBytes": marker.baselineSizeBytes = exactLong(reader); break;
                    case "candidateSha256": marker.candidateSha256 = requiredString(reader); break;
                    case "candidateSizeBytes": marker.candidateSizeBytes = exactLong(reader); break;
                    case "fabricId": marker.fabricId = requiredString(reader); break;
                    case "fabricVersion": marker.fabricVersion = requiredString(reader); break;
                    case "minecraftDependency": marker.minecraftDependency = requiredString(reader); break;
                    case "javaDependency": marker.javaDependency = requiredString(reader); break;
                    case "otherModsFingerprintSha256":
                        marker.otherModsFingerprintSha256 = requiredString(reader); break;
                    case "openXrCopyBatchMode":
                        marker.openXrCopyBatchMode = requiredString(reader); break;
                    case "expiresAtEpochMs": marker.expiresAtEpochMs = exactLong(reader); break;
                    case "maxLaunches": marker.maxLaunches = exactInt(reader); break;
                    default: throw new IOException("Unsupported marker field");
                }
            }
            reader.endObject();
            if(reader.peek() != JsonToken.END_DOCUMENT || !seen.equals(MARKER_FIELDS)) {
                throw new IOException("Marker fields are incomplete or trailing data exists");
            }
            normalizeMarkerHashes(marker);
            return marker;
        } catch(IllegalStateException | NumberFormatException e) {
            throw new IOException("Invalid marker JSON", e);
        }
    }

    static void writeMarkerAtomically(Layout layout, Marker marker) throws IOException {
        Path stage = layout.markerStage(marker.runId);
        if(Files.isSymbolicLink(stage) || Files.isSymbolicLink(layout.marker)) {
            throw new IOException("Marker path is a symbolic link");
        }
        Files.deleteIfExists(stage);
        try(FileOutputStream file = new FileOutputStream(stage.toFile());
                BufferedOutputStream buffered = new BufferedOutputStream(file);
                OutputStreamWriter output = new OutputStreamWriter(buffered, StandardCharsets.UTF_8);
                JsonWriter writer = new JsonWriter(output)) {
            writer.setIndent("  ");
            writer.beginObject();
            writer.name("schemaVersion").value(marker.schemaVersion);
            writer.name("harnessId").value(marker.harnessId);
            writer.name("state").value(marker.state);
            writer.name("packageName").value(marker.packageName);
            writer.name("profile").value(marker.profile);
            writer.name("target").value(marker.target);
            writer.name("runId").value(marker.runId);
            writer.name("baselineSha256").value(marker.baselineSha256);
            writer.name("baselineSizeBytes").value(marker.baselineSizeBytes);
            writer.name("candidateSha256").value(marker.candidateSha256);
            writer.name("candidateSizeBytes").value(marker.candidateSizeBytes);
            writer.name("fabricId").value(marker.fabricId);
            writer.name("fabricVersion").value(marker.fabricVersion);
            writer.name("minecraftDependency").value(marker.minecraftDependency);
            writer.name("javaDependency").value(marker.javaDependency);
            writer.name("otherModsFingerprintSha256").value(marker.otherModsFingerprintSha256);
            writer.name("openXrCopyBatchMode").value(marker.openXrCopyBatchMode);
            writer.name("expiresAtEpochMs").value(marker.expiresAtEpochMs);
            writer.name("maxLaunches").value(marker.maxLaunches);
            writer.endObject();
            writer.flush();
            buffered.flush();
            file.getFD().sync();
        } catch(IOException failure) {
            Files.deleteIfExists(stage);
            throw failure;
        }
        atomicMove(stage, layout.marker);
    }

    static String sha256(Path file) throws IOException {
        MessageDigest digest = newSha256();
        try(InputStream input = new BufferedInputStream(new FileInputStream(file.toFile()))) {
            byte[] buffer = new byte[64 * 1024];
            int read;
            while((read = input.read(buffer)) != -1) {
                digest.update(buffer, 0, read);
            }
        }
        return toHex(digest.digest());
    }

    static String fingerprintOtherMods(Path modsDirectory, Path target) throws IOException {
        return fingerprintOtherMods(modsDirectory, Collections.singleton(target));
    }

    /**
     * Fingerprints every managed JAR except the exact canary targets supplied by the caller.
     *
     * <p>The v70 Lab may promote Vivecraft and VEQ in one prelaunch. Excluding both exact
     * managed leaves keeps the surrounding-stack fingerprint stable while either target is
     * promoted. Each excluded artifact is still hash/size/metadata verified by its own Permit
     * and by {@code UnattendedStackVerifier}; this overload does not make either target
     * unverified.</p>
     */
    static String fingerprintOtherMods(Path modsDirectory, Path firstTarget, Path secondTarget)
            throws IOException {
        Set<Path> excluded = new HashSet<>();
        excluded.add(firstTarget);
        excluded.add(secondTarget);
        return fingerprintOtherMods(modsDirectory, excluded);
    }

    private static String fingerprintOtherMods(Path modsDirectory, Set<Path> targets)
            throws IOException {
        Path realMods = modsDirectory.toRealPath(LinkOption.NOFOLLOW_LINKS);
        if(Files.isSymbolicLink(modsDirectory) || !Files.isDirectory(realMods, LinkOption.NOFOLLOW_LINKS)) {
            throw new IOException("Invalid mods directory");
        }
        Path normalizedMods = modsDirectory.toAbsolutePath().normalize();
        Set<Path> normalizedTargets = new HashSet<>();
        for(Path target : targets) {
            if(target == null) {
                throw new IOException("Null fingerprint exclusion");
            }
            Path normalizedTarget = target.toAbsolutePath().normalize();
            if(!normalizedMods.equals(normalizedTarget.getParent())) {
                throw new IOException("Fingerprint exclusion escaped the mods directory");
            }
            normalizedTargets.add(normalizedTarget);
        }
        if(normalizedTargets.isEmpty()) {
            throw new IOException("No fingerprint target was supplied");
        }
        List<String> rows = new ArrayList<>();
        try(DirectoryStream<Path> entries = Files.newDirectoryStream(realMods)) {
            for(Path entry : entries) {
                Path absolute = entry.toAbsolutePath().normalize();
                String name = entry.getFileName().toString();
                if(normalizedTargets.contains(absolute) ||
                        !name.toLowerCase(Locale.ROOT).endsWith(".jar")) {
                    continue;
                }
                if(Files.isSymbolicLink(entry) || !Files.isRegularFile(entry, LinkOption.NOFOLLOW_LINKS)) {
                    throw new IOException("Non-regular JAR in mods directory");
                }
                if(name.indexOf('\t') >= 0 || name.indexOf('\r') >= 0 || name.indexOf('\n') >= 0 ||
                        name.indexOf('\0') >= 0) {
                    throw new IOException("Control character in mod filename");
                }
                rows.add(name + "\t" + sha256(entry) + "\n");
            }
        }
        rows.sort(VivecraftCoreCanaryTransaction::compareUtf8);
        MessageDigest digest = newSha256();
        for(String row : rows) {
            digest.update(row.getBytes(StandardCharsets.UTF_8));
        }
        return toHex(digest.digest());
    }

    private static int compareUtf8(String left, String right) {
        byte[] a = left.getBytes(StandardCharsets.UTF_8);
        byte[] b = right.getBytes(StandardCharsets.UTF_8);
        int common = Math.min(a.length, b.length);
        for(int index = 0; index < common; index++) {
            int comparison = Integer.compare(a[index] & 0xff, b[index] & 0xff);
            if(comparison != 0) {
                return comparison;
            }
        }
        return Integer.compare(a.length, b.length);
    }

    static void inspectCandidateJar(Path candidate, Marker marker) throws IOException {
        long size = Files.size(candidate);
        if(size <= 0 || size > MAX_CANDIDATE_BYTES) {
            throw new IOException("Candidate size is outside the fixed limit");
        }
        inspectCentralDirectory(candidate);
        try(ZipFile archive = new ZipFile(candidate.toFile())) {
            ZipEntry metadata = archive.getEntry("fabric.mod.json");
            if(metadata == null || metadata.isDirectory() || metadata.getSize() < 0 ||
                    metadata.getSize() > MAX_FABRIC_METADATA_BYTES) {
                throw new IOException("Missing or oversized fabric.mod.json");
            }
            byte[] bytes;
            try(InputStream input = archive.getInputStream(metadata)) {
                bytes = readAtMost(input, MAX_FABRIC_METADATA_BYTES);
            }
            FabricMetadata actual = FabricMetadata.parse(bytes);
            if(!marker.fabricId.equals(actual.id) || !marker.fabricVersion.equals(actual.version) ||
                    !marker.minecraftDependency.equals(actual.minecraftDependency) ||
                    !marker.javaDependency.equals(actual.javaDependency)) {
                throw new IOException("Fabric metadata does not match the armed marker");
            }
        }
    }

    static final class FabricMetadata {
        final String id;
        final String version;
        final String minecraftDependency;
        final String javaDependency;

        FabricMetadata(String id, String version, String minecraftDependency, String javaDependency) {
            this.id = id;
            this.version = version;
            this.minecraftDependency = minecraftDependency;
            this.javaDependency = javaDependency;
        }

        static FabricMetadata parse(byte[] bytes) throws IOException {
            com.google.gson.JsonElement parsed;
            try {
                parsed = com.google.gson.JsonParser.parseReader(new InputStreamReader(
                        new ByteArrayInputStream(bytes), StandardCharsets.UTF_8));
            } catch(RuntimeException e) {
                throw new IOException("Invalid fabric.mod.json", e);
            }
            if(!parsed.isJsonObject()) {
                throw new IOException("fabric.mod.json is not an object");
            }
            com.google.gson.JsonObject root = parsed.getAsJsonObject();
            String id = exactJsonString(root, "id");
            String version = exactJsonString(root, "version");
            com.google.gson.JsonElement dependsElement = root.get("depends");
            if(dependsElement == null || !dependsElement.isJsonObject()) {
                throw new IOException("fabric.mod.json has no depends object");
            }
            com.google.gson.JsonObject depends = dependsElement.getAsJsonObject();
            return new FabricMetadata(id, version,
                    exactDependencyOrAbsent(depends.get("minecraft"), "minecraft"),
                    exactDependencyOrAbsent(depends.get("java"), "java"));
        }

        private static String exactJsonString(com.google.gson.JsonObject object, String name)
                throws IOException {
            com.google.gson.JsonElement value = object.get(name);
            if(value == null || !value.isJsonPrimitive() ||
                    !value.getAsJsonPrimitive().isString() || value.getAsString().isEmpty()) {
                throw new IOException("Invalid fabric metadata field " + name);
            }
            return value.getAsString();
        }

        private static String exactDependency(com.google.gson.JsonElement value, String name)
                throws IOException {
            if(value != null && value.isJsonPrimitive() && value.getAsJsonPrimitive().isString()) {
                return value.getAsString();
            }
            if(value != null && value.isJsonArray() && value.getAsJsonArray().size() == 1 &&
                    value.getAsJsonArray().get(0).isJsonPrimitive() &&
                    value.getAsJsonArray().get(0).getAsJsonPrimitive().isString()) {
                return value.getAsJsonArray().get(0).getAsString();
            }
            throw new IOException("Dependency " + name + " must have one exact string value");
        }

        /**
         * A few official Fabric artifacts deliberately omit Minecraft/Java
         * dependency keys.  Keep that absence explicit in the signed marker
         * contract rather than weakening metadata comparison or inventing a
         * wildcard dependency.
         */
        private static String exactDependencyOrAbsent(
                com.google.gson.JsonElement value, String name) throws IOException {
            return value == null ? ABSENT_DEPENDENCY : exactDependency(value, name);
        }
    }

    private static boolean validIdentity(Marker marker, Contract contract) {
        try {
            boolean common = marker.schemaVersion == SCHEMA_VERSION &&
                    contract.harnessId.equals(marker.harnessId) &&
                    contract.packageName.equals(marker.packageName) &&
                    contract.profile.equals(marker.profile) &&
                    contract.target.equals(marker.target) &&
                    marker.runId != null && marker.runId.matches("^[0-9a-f]{32}$");
            if(!common) {
                return false;
            }
            if(STATE_ARMED.equals(marker.state)) {
                return validArmedIdentity(marker, contract);
            }
            return validTerminalIdentity(marker, contract);
        } catch(RuntimeException ignored) {
            return false;
        }
    }

    private static boolean validTerminalIdentity(Marker marker, Contract contract) {
        boolean stateKnown = STATE_ATTEMPTING.equals(marker.state) || STATE_CONSUMED.equals(marker.state) ||
                STATE_EXPIRED.equals(marker.state);
        return marker.schemaVersion == SCHEMA_VERSION && stateKnown &&
                contract.harnessId.equals(marker.harnessId) &&
                contract.packageName.equals(marker.packageName) &&
                contract.profile.equals(marker.profile) &&
                contract.target.equals(marker.target) &&
                marker.runId != null && marker.runId.matches("^[0-9a-f]{32}$") &&
                contract.baselineSha256.equals(marker.baselineSha256) &&
                contract.baselineSizeBytes == marker.baselineSizeBytes &&
                contract.otherModsFingerprintSha256.equals(marker.otherModsFingerprintSha256) &&
                marker.maxLaunches == 1 && marker.expiresAtEpochMs > 0 &&
                validCandidateFields(marker, contract);
    }

    private static boolean validArmedIdentity(Marker marker, Contract contract) {
        return contract.baselineSha256.equals(marker.baselineSha256) &&
                contract.baselineSizeBytes == marker.baselineSizeBytes &&
                contract.otherModsFingerprintSha256.equals(marker.otherModsFingerprintSha256) &&
                marker.maxLaunches == 1 && marker.expiresAtEpochMs > 0 &&
                (marker.expiresAtEpochMs <= contract.nowEpochMs ||
                        marker.expiresAtEpochMs - contract.nowEpochMs <= MAX_ARM_TTL_MS) &&
                validCandidateFields(marker, contract);
    }

    private static boolean validCandidateFields(Marker marker, Contract contract) {
        return marker.candidateSizeBytes > 0 && marker.candidateSizeBytes <= MAX_CANDIDATE_BYTES &&
                marker.candidateSha256 != null && marker.candidateSha256.matches("^[0-9a-f]{64}$") &&
                (!contract.candidateShaAllowlistEnforced ||
                        contract.allowedCandidateSha256s.contains(marker.candidateSha256)) &&
                contract.fabricId.equals(marker.fabricId) && nonBlank(marker.fabricVersion) &&
                (contract.fabricVersion == null ||
                        contract.fabricVersion.equals(marker.fabricVersion)) &&
                contract.minecraftDependency.equals(marker.minecraftDependency) &&
                contract.javaDependency.equals(marker.javaDependency) &&
                (OPENXR_COPY_BATCH_OFF.equals(marker.openXrCopyBatchMode) ||
                        OPENXR_COPY_BATCH_ON.equals(marker.openXrCopyBatchMode));
    }

    private static boolean nonBlank(String value) {
        return value != null && !value.trim().isEmpty() && value.equals(value.trim());
    }

    private static String safeRestoreRunId(String runId) {
        return runId != null && runId.matches("^[0-9a-f]{32}$") ? runId : "invalid";
    }

    private static void normalizeMarkerHashes(Marker marker) throws IOException {
        try {
            marker.baselineSha256 = normalizedSha256(marker.baselineSha256);
            marker.candidateSha256 = normalizedSha256(marker.candidateSha256);
            marker.otherModsFingerprintSha256 = normalizedSha256(marker.otherModsFingerprintSha256);
        } catch(IllegalArgumentException e) {
            throw new IOException("Invalid SHA-256 in marker", e);
        }
    }

    private static String normalizedSha256(String value) {
        if(value == null || !value.matches("(?i)^[0-9a-f]{64}$")) {
            throw new IllegalArgumentException("Invalid SHA-256");
        }
        return value.toLowerCase(Locale.ROOT);
    }

    private static void requireRegularFile(Path file, String label) throws IOException {
        if(Files.isSymbolicLink(file) || !Files.isRegularFile(file, LinkOption.NOFOLLOW_LINKS)) {
            throw new IOException(label + " is not a regular file");
        }
    }

    private static void requireExactFile(Path file, long size, String hash, String label)
            throws IOException {
        requireRegularFile(file, label);
        if(size <= 0 || Files.size(file) != size || !normalizedSha256(hash).equals(sha256(file))) {
            throw new IOException(label + " does not match its exact lock");
        }
    }

    private static void restoreBaseline(Layout layout, Contract contract, String runId) throws IOException {
        if(Files.isRegularFile(layout.target, LinkOption.NOFOLLOW_LINKS) &&
                !Files.isSymbolicLink(layout.target) && Files.size(layout.target) == contract.baselineSizeBytes &&
                contract.baselineSha256.equals(sha256(layout.target))) {
            return;
        }
        requireExactFile(layout.baselineSource, contract.baselineSizeBytes, contract.baselineSha256,
                "baseline source");
        String safeRunId = runId != null && runId.matches("^[0-9a-f]{32}$") ? runId : "invalid";
        Path stage = layout.baselineRestoreStage(safeRunId);
        if(Files.isSymbolicLink(stage)) {
            throw new IOException("Baseline restore stage is a symbolic link");
        }
        Files.deleteIfExists(stage);
        try {
            Files.copy(layout.baselineSource, stage);
            requireExactFile(stage, contract.baselineSizeBytes, contract.baselineSha256,
                    "baseline restore stage");
            atomicMove(stage, layout.target);
            requireExactFile(layout.target, contract.baselineSizeBytes, contract.baselineSha256,
                    "restored baseline");
        } finally {
            Files.deleteIfExists(stage);
        }
    }

    private static void deleteCandidateIfSafe(Layout layout, Marker marker) throws IOException {
        Path candidate = layout.candidate(marker.runId);
        if(Files.isSymbolicLink(candidate)) {
            throw new IOException("Candidate is a symbolic link");
        }
        Files.deleteIfExists(candidate);
    }

    private static void quarantineMarker(Layout layout) throws IOException {
        if(Files.isSymbolicLink(layout.rejectedMarker)) {
            throw new IOException("Rejected marker path is a symbolic link");
        }
        atomicMove(layout.marker, layout.rejectedMarker);
    }

    private static void atomicMove(Path source, Path destination) throws IOException {
        try {
            Files.move(source, destination, StandardCopyOption.ATOMIC_MOVE,
                    StandardCopyOption.REPLACE_EXISTING);
        } catch(AtomicMoveNotSupportedException e) {
            throw new IOException("Atomic rename is required", e);
        }
    }

    private static int exactInt(JsonReader reader) throws IOException {
        long value = exactLong(reader);
        if(value < Integer.MIN_VALUE || value > Integer.MAX_VALUE) {
            throw new IOException("Integer is outside range");
        }
        return (int)value;
    }

    private static long exactLong(JsonReader reader) throws IOException {
        if(reader.peek() != JsonToken.NUMBER) {
            throw new IOException("Expected JSON integer");
        }
        String raw = reader.nextString();
        if(!raw.matches("^-?(0|[1-9][0-9]*)$")) {
            throw new IOException("Expected canonical JSON integer");
        }
        try {
            return Long.parseLong(raw);
        } catch(NumberFormatException e) {
            throw new IOException("JSON integer is outside range", e);
        }
    }

    private static String requiredString(JsonReader reader) throws IOException {
        if(reader.peek() != JsonToken.STRING) {
            throw new IOException("Expected JSON string");
        }
        String value = reader.nextString();
        if(value.isEmpty()) {
            throw new IOException("Empty marker string");
        }
        return value;
    }

    private static byte[] readAtMost(InputStream input, int maximum) throws IOException {
        ByteArrayOutputStream output = new ByteArrayOutputStream();
        byte[] buffer = new byte[8192];
        int total = 0;
        int read;
        while((read = input.read(buffer)) != -1) {
            total += read;
            if(total > maximum) {
                throw new IOException("ZIP entry exceeds limit");
            }
            output.write(buffer, 0, read);
        }
        return output.toByteArray();
    }

    private static void inspectCentralDirectory(Path archive) throws IOException {
        byte[] bytes = Files.readAllBytes(archive);
        int eocd = findEocd(bytes);
        ByteBuffer eocdView = ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN);
        int disk = unsignedShort(eocdView, eocd + 4);
        int centralDisk = unsignedShort(eocdView, eocd + 6);
        int diskEntries = unsignedShort(eocdView, eocd + 8);
        int totalEntries = unsignedShort(eocdView, eocd + 10);
        long centralSize = unsignedInt(eocdView, eocd + 12);
        long centralOffset = unsignedInt(eocdView, eocd + 16);
        if(disk != 0 || centralDisk != 0 || diskEntries != totalEntries || totalEntries <= 0 ||
                totalEntries > MAX_ARCHIVE_ENTRIES || diskEntries == 0xffff ||
                centralSize == 0xffffffffL || centralOffset == 0xffffffffL ||
                centralOffset + centralSize > eocd || centralOffset > Integer.MAX_VALUE) {
            throw new IOException("Unsupported or multi-device ZIP layout");
        }

        int cursor = (int)centralOffset;
        long uncompressedTotal = 0;
        Set<String> names = new HashSet<>();
        int fabricMetadataCount = 0;
        for(int index = 0; index < totalEntries; index++) {
            requireRange(bytes, cursor, 46);
            if(unsignedInt(eocdView, cursor) != 0x02014b50L) {
                throw new IOException("Invalid central directory signature");
            }
            int madeBy = unsignedShort(eocdView, cursor + 4);
            int flags = unsignedShort(eocdView, cursor + 8);
            long uncompressed = unsignedInt(eocdView, cursor + 24);
            int nameLength = unsignedShort(eocdView, cursor + 28);
            int extraLength = unsignedShort(eocdView, cursor + 30);
            int commentLength = unsignedShort(eocdView, cursor + 32);
            long externalAttributes = unsignedInt(eocdView, cursor + 38);
            int recordLength = 46 + nameLength + extraLength + commentLength;
            requireRange(bytes, cursor, recordLength);
            String name = decodeZipName(bytes, cursor + 46, nameLength, (flags & 0x0800) != 0);
            validateEntryName(name);
            String collisionKey = name.toLowerCase(Locale.ROOT);
            if(!names.add(collisionKey)) {
                throw new IOException("Duplicate ZIP entry");
            }
            if("fabric.mod.json".equals(name)) {
                fabricMetadataCount++;
            }
            int creatorSystem = (madeBy >>> 8) & 0xff;
            int unixMode = (int)((externalAttributes >>> 16) & 0xffff);
            if(creatorSystem == 3 && (unixMode & 0170000) == 0120000) {
                throw new IOException("Symbolic-link ZIP entry rejected");
            }
            uncompressedTotal += uncompressed;
            if(uncompressedTotal > MAX_ARCHIVE_UNCOMPRESSED_BYTES) {
                throw new IOException("ZIP expansion exceeds limit");
            }
            cursor += recordLength;
        }
        if(fabricMetadataCount != 1 || cursor != centralOffset + centralSize) {
            throw new IOException("ZIP central directory or fabric.mod.json count is invalid");
        }
    }

    private static int findEocd(byte[] bytes) throws IOException {
        int minimum = Math.max(0, bytes.length - 65557);
        for(int index = bytes.length - 22; index >= minimum; index--) {
            if((bytes[index] & 0xff) == 0x50 && (bytes[index + 1] & 0xff) == 0x4b &&
                    (bytes[index + 2] & 0xff) == 0x05 && (bytes[index + 3] & 0xff) == 0x06) {
                int comment = (bytes[index + 20] & 0xff) | ((bytes[index + 21] & 0xff) << 8);
                if(index + 22 + comment == bytes.length) {
                    return index;
                }
            }
        }
        throw new IOException("ZIP end record not found");
    }

    private static String decodeZipName(byte[] bytes, int offset, int length, boolean utf8)
            throws IOException {
        requireRange(bytes, offset, length);
        if(!utf8) {
            for(int index = offset; index < offset + length; index++) {
                if((bytes[index] & 0x80) != 0) {
                    throw new IOException("Non-UTF8 non-ASCII ZIP name rejected");
                }
            }
            return new String(bytes, offset, length, StandardCharsets.US_ASCII);
        }
        try {
            return StandardCharsets.UTF_8.newDecoder()
                    .onMalformedInput(CodingErrorAction.REPORT)
                    .onUnmappableCharacter(CodingErrorAction.REPORT)
                    .decode(ByteBuffer.wrap(bytes, offset, length)).toString();
        } catch(CharacterCodingException e) {
            throw new IOException("Invalid UTF-8 ZIP entry name", e);
        }
    }

    private static void validateEntryName(String name) throws IOException {
        if(name.isEmpty() || name.startsWith("/") || name.startsWith("\\") ||
                name.indexOf('\\') >= 0 || name.indexOf(':') >= 0 || name.indexOf('\0') >= 0) {
            throw new IOException("Unsafe ZIP entry path");
        }
        String content = name.endsWith("/") ? name.substring(0, name.length() - 1) : name;
        if(content.isEmpty()) {
            throw new IOException("Unsafe ZIP root entry");
        }
        for(String segment : content.split("/", -1)) {
            if(segment.isEmpty() || ".".equals(segment) || "..".equals(segment)) {
                throw new IOException("Unsafe ZIP entry segment");
            }
        }
    }

    private static void requireRange(byte[] bytes, int offset, int length) throws EOFException {
        if(offset < 0 || length < 0 || offset > bytes.length - length) {
            throw new EOFException("ZIP structure is truncated");
        }
    }

    private static int unsignedShort(ByteBuffer buffer, int offset) {
        return buffer.getShort(offset) & 0xffff;
    }

    private static long unsignedInt(ByteBuffer buffer, int offset) {
        return buffer.getInt(offset) & 0xffffffffL;
    }

    private static MessageDigest newSha256() {
        try {
            return MessageDigest.getInstance("SHA-256");
        } catch(NoSuchAlgorithmException e) {
            throw new IllegalStateException("SHA-256 is unavailable", e);
        }
    }

    private static String toHex(byte[] bytes) {
        StringBuilder value = new StringBuilder(bytes.length * 2);
        for(byte item : bytes) {
            value.append(String.format(Locale.ROOT, "%02x", item & 0xff));
        }
        return value.toString();
    }
}
