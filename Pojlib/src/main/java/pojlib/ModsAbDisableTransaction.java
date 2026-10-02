package pojlib;

import java.io.IOException;
import java.nio.channels.FileChannel;
import java.nio.channels.FileLock;
import java.nio.channels.OverlappingFileLockException;
import java.nio.file.AtomicMoveNotSupportedException;
import java.nio.file.Files;
import java.nio.file.LinkOption;
import java.nio.file.Path;
import java.nio.file.StandardCopyOption;
import java.nio.file.StandardOpenOption;
import java.util.Locale;

/**
 * Pure-Java, one-shot transaction used by the Lab mod-removal experiments.
 *
 * <p>The selected JAR is never deleted during promotion.  It is atomically
 * moved into harness-owned state, so any failure and the next prelaunch can
 * restore the exact baseline without network access.</p>
 */
final class ModsAbDisableTransaction {
    static final String ABSENT_SHA256 =
            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855";
    static final String ABSENT_VALUE = "<absent>";

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
        BASELINE_HELD,
        ABSENCE_VERIFIED,
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
        final String fabricId;
        final String baselineSha256;
        final long baselineSizeBytes;
        final String otherModsFingerprintSha256;
        final long nowEpochMs;

        Contract(String harnessId, String packageName, String profile, String target,
                 String fabricId, String baselineSha256, long baselineSizeBytes,
                 String otherModsFingerprintSha256, long nowEpochMs) {
            if(!nonBlank(harnessId) || !nonBlank(packageName) || !nonBlank(profile) ||
                    !nonBlank(target) || !nonBlank(fabricId) || baselineSizeBytes <= 0) {
                throw new IllegalArgumentException("Invalid disable transaction contract");
            }
            this.harnessId = harnessId;
            this.packageName = packageName;
            this.profile = profile;
            this.target = target;
            this.fabricId = fabricId;
            this.baselineSha256 = normalizedSha256(baselineSha256);
            this.baselineSizeBytes = baselineSizeBytes;
            this.otherModsFingerprintSha256 = normalizedSha256(otherModsFingerprintSha256);
            this.nowEpochMs = nowEpochMs;
        }
    }

    static final class Permit {
        final String runId;
        final Path target;
        final Path baselineSource;
        final Path heldBaseline;
        final Path lock;
        final String baselineSha256;
        final long baselineSizeBytes;
        final String otherModsFingerprintSha256;

        Permit(VivecraftCoreCanaryTransaction.Marker marker,
               VivecraftCoreCanaryTransaction.Layout layout) {
            runId = marker.runId;
            target = layout.target;
            baselineSource = layout.baselineSource;
            heldBaseline = heldBaseline(layout, marker.runId);
            lock = layout.lock;
            baselineSha256 = marker.baselineSha256;
            baselineSizeBytes = marker.baselineSizeBytes;
            otherModsFingerprintSha256 = marker.otherModsFingerprintSha256;
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

    private ModsAbDisableTransaction() {
    }

    static Result execute(VivecraftCoreCanaryTransaction.Layout layout, Contract contract,
                          FaultInjector faults) {
        if(!Files.exists(layout.marker, LinkOption.NOFOLLOW_LINKS)) {
            return new Result(Outcome.BASELINE, null, "no-marker");
        }
        if(Files.isSymbolicLink(layout.stateDirectory) || Files.isSymbolicLink(layout.marker) ||
                Files.isSymbolicLink(layout.lock) || Files.isSymbolicLink(layout.target) ||
                Files.isSymbolicLink(layout.baselineSource)) {
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

    private static Result executeLocked(VivecraftCoreCanaryTransaction.Layout layout,
                                        Contract contract, FaultInjector faults) throws IOException {
        VivecraftCoreCanaryTransaction.Marker marker;
        try {
            marker = VivecraftCoreCanaryTransaction.readMarker(layout.marker);
        } catch(IOException | RuntimeException invalid) {
            restoreBaseline(layout, contract, "invalid");
            quarantineMarker(layout);
            return new Result(Outcome.INVALID_QUARANTINED, null, "invalid-marker");
        }
        if(!validIdentity(marker, contract)) {
            restoreBaseline(layout, contract, safeRunId(marker.runId));
            quarantineMarker(layout);
            return new Result(Outcome.INVALID_QUARANTINED, null, "contract-mismatch");
        }
        if(!VivecraftCoreCanaryTransaction.STATE_ARMED.equals(marker.state)) {
            restoreBaseline(layout, contract, marker.runId);
            deleteHeldIfRestored(layout, contract, marker.runId);
            return new Result(Outcome.TERMINAL_RESTORED, null, "terminal-" + marker.state);
        }
        if(marker.expiresAtEpochMs <= contract.nowEpochMs) {
            VivecraftCoreCanaryTransaction.writeMarkerAtomically(layout,
                    marker.withState(VivecraftCoreCanaryTransaction.STATE_EXPIRED));
            restoreBaseline(layout, contract, marker.runId);
            deleteHeldIfRestored(layout, contract, marker.runId);
            return new Result(Outcome.TERMINAL_RESTORED, null, "expired");
        }

        boolean attemptCommitted = false;
        boolean baselineHeld = false;
        try {
            requireExactFile(layout.baselineSource, contract.baselineSizeBytes,
                    contract.baselineSha256, "baseline source");
            requireExactFile(layout.target, contract.baselineSizeBytes,
                    contract.baselineSha256, "managed baseline");
            Path held = heldBaseline(layout, marker.runId);
            requireAbsent(held, "held baseline");
            requireAbsent(layout.candidate(marker.runId), "disable candidate");
            faults.after(Stage.VALIDATED);

            VivecraftCoreCanaryTransaction.writeMarkerAtomically(layout,
                    marker.withState(VivecraftCoreCanaryTransaction.STATE_ATTEMPTING));
            attemptCommitted = true;
            faults.after(Stage.ATTEMPTING_COMMITTED);

            atomicMove(layout.target, held);
            baselineHeld = true;
            faults.after(Stage.BASELINE_HELD);
            requireAbsent(layout.target, "disabled target");
            requireExactFile(held, contract.baselineSizeBytes, contract.baselineSha256,
                    "held baseline");
            faults.after(Stage.ABSENCE_VERIFIED);

            VivecraftCoreCanaryTransaction.writeMarkerAtomically(layout,
                    marker.withState(VivecraftCoreCanaryTransaction.STATE_CONSUMED));
            faults.after(Stage.CONSUMED_COMMITTED);
            Permit permit = new Permit(marker, layout);
            faults.after(Stage.PERMIT_PUBLISHED);
            return new Result(Outcome.PROMOTED, permit, "baseline-disabled");
        } catch(IOException | RuntimeException failure) {
            try {
                restoreBaseline(layout, contract, marker.runId);
                deleteHeldIfRestored(layout, contract, marker.runId);
                if(attemptCommitted || baselineHeld) {
                    VivecraftCoreCanaryTransaction.writeMarkerAtomically(layout,
                            marker.withState(VivecraftCoreCanaryTransaction.STATE_CONSUMED));
                } else {
                    quarantineMarker(layout);
                }
            } catch(IOException restoreFailure) {
                failure.addSuppressed(restoreFailure);
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
            if(ignored == null || Files.isSymbolicLink(permit.target) ||
                    Files.isSymbolicLink(permit.heldBaseline) ||
                    Files.isSymbolicLink(permit.baselineSource)) {
                return false;
            }
            restorePermitBaseline(permit);
            return true;
        } catch(IOException | RuntimeException ignored) {
            return false;
        }
    }

    static boolean permitMatchesAbsence(Permit permit, Path target,
                                        String otherModsFingerprintSha256) {
        if(permit == null || target == null || otherModsFingerprintSha256 == null) {
            return false;
        }
        try {
            Path normalized = target.toAbsolutePath().normalize();
            return permit.target.toAbsolutePath().normalize().equals(normalized) &&
                    !Files.exists(normalized, LinkOption.NOFOLLOW_LINKS) &&
                    !Files.isSymbolicLink(normalized) &&
                    permit.otherModsFingerprintSha256.equals(
                            normalizedSha256(otherModsFingerprintSha256)) &&
                    exactFile(permit.heldBaseline, permit.baselineSizeBytes,
                            permit.baselineSha256);
        } catch(IOException | RuntimeException ignored) {
            return false;
        }
    }

    private static boolean validIdentity(VivecraftCoreCanaryTransaction.Marker marker,
                                         Contract contract) {
        try {
            boolean stateKnown = VivecraftCoreCanaryTransaction.STATE_ARMED.equals(marker.state) ||
                    VivecraftCoreCanaryTransaction.STATE_ATTEMPTING.equals(marker.state) ||
                    VivecraftCoreCanaryTransaction.STATE_CONSUMED.equals(marker.state) ||
                    VivecraftCoreCanaryTransaction.STATE_EXPIRED.equals(marker.state);
            boolean common = marker.schemaVersion == VivecraftCoreCanaryTransaction.SCHEMA_VERSION &&
                    stateKnown && contract.harnessId.equals(marker.harnessId) &&
                    contract.packageName.equals(marker.packageName) &&
                    contract.profile.equals(marker.profile) &&
                    contract.target.equals(marker.target) &&
                    marker.runId != null && marker.runId.matches("^[0-9a-f]{32}$") &&
                    contract.baselineSha256.equals(marker.baselineSha256) &&
                    contract.baselineSizeBytes == marker.baselineSizeBytes &&
                    ABSENT_SHA256.equals(marker.candidateSha256) &&
                    marker.candidateSizeBytes == 0 &&
                    contract.fabricId.equals(marker.fabricId) &&
                    ABSENT_VALUE.equals(marker.fabricVersion) &&
                    ABSENT_VALUE.equals(marker.minecraftDependency) &&
                    ABSENT_VALUE.equals(marker.javaDependency) &&
                    contract.otherModsFingerprintSha256.equals(
                            marker.otherModsFingerprintSha256) &&
                    marker.maxLaunches == 1 && marker.expiresAtEpochMs > 0;
            return common && (!VivecraftCoreCanaryTransaction.STATE_ARMED.equals(marker.state) ||
                    marker.expiresAtEpochMs <= contract.nowEpochMs ||
                    marker.expiresAtEpochMs - contract.nowEpochMs <=
                            VivecraftCoreCanaryTransaction.MAX_ARM_TTL_MS);
        } catch(RuntimeException ignored) {
            return false;
        }
    }

    private static void restoreBaseline(VivecraftCoreCanaryTransaction.Layout layout,
                                        Contract contract, String runId) throws IOException {
        if(exactFile(layout.target, contract.baselineSizeBytes, contract.baselineSha256)) {
            return;
        }
        Path held = heldBaseline(layout, safeRunId(runId));
        if(exactFile(held, contract.baselineSizeBytes, contract.baselineSha256)) {
            atomicMove(held, layout.target);
            requireExactFile(layout.target, contract.baselineSizeBytes,
                    contract.baselineSha256, "restored baseline");
            return;
        }
        requireExactFile(layout.baselineSource, contract.baselineSizeBytes,
                contract.baselineSha256, "baseline source");
        Path stage = layout.target.resolveSibling(".mods-ab-baseline-" + safeRunId(runId) + ".tmp");
        requireAbsent(stage, "baseline restore stage");
        try {
            Files.copy(layout.baselineSource, stage);
            requireExactFile(stage, contract.baselineSizeBytes,
                    contract.baselineSha256, "baseline restore stage");
            atomicMove(stage, layout.target);
            requireExactFile(layout.target, contract.baselineSizeBytes,
                    contract.baselineSha256, "restored baseline");
        } finally {
            Files.deleteIfExists(stage);
        }
    }

    private static void restorePermitBaseline(Permit permit) throws IOException {
        if(exactFile(permit.target, permit.baselineSizeBytes, permit.baselineSha256)) {
            Files.deleteIfExists(permit.heldBaseline);
            return;
        }
        if(exactFile(permit.heldBaseline, permit.baselineSizeBytes, permit.baselineSha256)) {
            atomicMove(permit.heldBaseline, permit.target);
            requireExactFile(permit.target, permit.baselineSizeBytes,
                    permit.baselineSha256, "restored baseline");
            return;
        }
        requireExactFile(permit.baselineSource, permit.baselineSizeBytes,
                permit.baselineSha256, "baseline source");
        Path stage = permit.target.resolveSibling(".mods-ab-baseline-" + permit.runId + ".tmp");
        requireAbsent(stage, "baseline restore stage");
        try {
            Files.copy(permit.baselineSource, stage);
            requireExactFile(stage, permit.baselineSizeBytes,
                    permit.baselineSha256, "baseline restore stage");
            atomicMove(stage, permit.target);
            requireExactFile(permit.target, permit.baselineSizeBytes,
                    permit.baselineSha256, "restored baseline");
        } finally {
            Files.deleteIfExists(stage);
        }
    }

    private static void deleteHeldIfRestored(VivecraftCoreCanaryTransaction.Layout layout,
                                             Contract contract, String runId) throws IOException {
        if(!exactFile(layout.target, contract.baselineSizeBytes, contract.baselineSha256)) {
            throw new IOException("baseline was not restored");
        }
        Path held = heldBaseline(layout, safeRunId(runId));
        if(Files.isSymbolicLink(held)) {
            throw new IOException("held baseline is a symbolic link");
        }
        Files.deleteIfExists(held);
    }

    private static Path heldBaseline(VivecraftCoreCanaryTransaction.Layout layout, String runId) {
        return layout.stateDirectory.resolve("disabled-" + runId + ".jar");
    }

    private static String safeRunId(String runId) {
        return runId != null && runId.matches("^[0-9a-f]{32}$") ? runId : "invalid";
    }

    private static FileLock tryLock(FileChannel channel) throws IOException {
        try {
            return channel.tryLock();
        } catch(OverlappingFileLockException e) {
            return null;
        }
    }

    private static boolean exactFile(Path file, long size, String hash) throws IOException {
        return !Files.isSymbolicLink(file) &&
                Files.isRegularFile(file, LinkOption.NOFOLLOW_LINKS) &&
                Files.size(file) == size && normalizedSha256(hash).equals(
                        VivecraftCoreCanaryTransaction.sha256(file));
    }

    private static void requireExactFile(Path file, long size, String hash, String label)
            throws IOException {
        if(!exactFile(file, size, hash)) {
            throw new IOException(label + " does not match its exact lock");
        }
    }

    private static void requireAbsent(Path path, String label) throws IOException {
        if(Files.exists(path, LinkOption.NOFOLLOW_LINKS) || Files.isSymbolicLink(path)) {
            throw new IOException(label + " must be absent");
        }
    }

    private static void quarantineMarker(VivecraftCoreCanaryTransaction.Layout layout)
            throws IOException {
        if(Files.isSymbolicLink(layout.rejectedMarker)) {
            throw new IOException("rejected marker path is a symbolic link");
        }
        atomicMove(layout.marker, layout.rejectedMarker);
    }

    private static void atomicMove(Path source, Path destination) throws IOException {
        try {
            Files.move(source, destination, StandardCopyOption.ATOMIC_MOVE,
                    StandardCopyOption.REPLACE_EXISTING);
        } catch(AtomicMoveNotSupportedException e) {
            throw new IOException("atomic rename is required", e);
        }
    }

    private static String normalizedSha256(String value) {
        if(value == null || !value.matches("(?i)^[0-9a-f]{64}$")) {
            throw new IllegalArgumentException("Invalid SHA-256");
        }
        return value.toLowerCase(Locale.ROOT);
    }

    private static boolean nonBlank(String value) {
        return value != null && !value.trim().isEmpty() && value.equals(value.trim());
    }
}
