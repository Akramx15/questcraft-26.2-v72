package pojlib;

import org.junit.After;
import org.junit.Before;
import org.junit.Test;

import java.io.IOException;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.Arrays;
import java.util.Collections;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicReference;
import java.util.zip.ZipEntry;
import java.util.zip.ZipOutputStream;

import static org.junit.Assert.assertArrayEquals;
import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertNotNull;
import static org.junit.Assert.assertNull;
import static org.junit.Assert.assertTrue;

public class VivecraftCoreCanaryTransactionTest {
    private static final String HARNESS = "questcraft-vivecraft-core-canary-v9";
    private static final String PACKAGE = "com.qcxr.qcxr.canary262";
    private static final String PROFILE = "26.2";
    private static final String TARGET = "mods/Vivecraft.jar";
    private static final String RUN = "0123456789abcdef0123456789abcdef";
    private static final long NOW = 1_800_000_000_000L;

    private Path root;

    @Before
    public void createRoot() throws Exception {
        root = Files.createTempDirectory("vivecraft-core-canary-");
    }

    @After
    public void removeRoot() throws Exception {
        if(root != null && Files.exists(root)) {
            Files.walk(root)
                    .sorted((left, right) -> right.getNameCount() - left.getNameCount())
                    .forEach(path -> {
                        try {
                            Files.deleteIfExists(path);
                        } catch(IOException e) {
                            throw new RuntimeException(e);
                        }
                    });
        }
    }

    @Test
    public void noMarkerIsAnExactNoOp() throws Exception {
        Fixture fixture = fixture("candidate-a");
        byte[] before = Files.readAllBytes(fixture.layout.target);

        VivecraftCoreCanaryTransaction.Result result = fixture.execute();

        assertEquals(VivecraftCoreCanaryTransaction.Outcome.BASELINE, result.outcome);
        assertNull(result.permit);
        assertArrayEquals(before, Files.readAllBytes(fixture.layout.target));
        assertFalse(Files.exists(fixture.layout.marker));
    }

    @Test
    public void validMarkerPromotesExactlyOnceAndPublishesProcessPermit() throws Exception {
        Fixture fixture = fixture("candidate-a");
        fixture.arm();

        VivecraftCoreCanaryTransaction.Result result = fixture.execute();

        assertEquals(VivecraftCoreCanaryTransaction.Outcome.PROMOTED, result.outcome);
        assertNotNull(result.permit);
        assertEquals(fixture.marker.candidateSha256,
                VivecraftCoreCanaryTransaction.sha256(fixture.layout.target));
        assertFalse(Files.exists(fixture.layout.candidate(RUN)));
        VivecraftCoreCanaryTransaction.Marker consumed =
                VivecraftCoreCanaryTransaction.readMarker(fixture.layout.marker);
        assertEquals(VivecraftCoreCanaryTransaction.STATE_CONSUMED, consumed.state);
        assertEquals(VivecraftCoreCanaryTransaction.OPENXR_COPY_BATCH_OFF,
                consumed.openXrCopyBatchMode);
        assertEquals(VivecraftCoreCanaryTransaction.OPENXR_COPY_BATCH_OFF,
                result.permit.openXrCopyBatchMode);
        assertTrue(VivecraftCoreCanaryTransaction.permitMatches(result.permit,
                fixture.layout.target, fixture.marker.candidateSha256,
                fixture.marker.candidateSizeBytes, fixture.contract.otherModsFingerprintSha256));
    }

    @Test
    public void consumedMarkerRestoresBaselineAndNeverRetries() throws Exception {
        Fixture fixture = fixture("candidate-a");
        fixture.arm();
        VivecraftCoreCanaryTransaction.Result promoted = fixture.execute();
        assertEquals(VivecraftCoreCanaryTransaction.Outcome.PROMOTED, promoted.outcome);

        VivecraftCoreCanaryTransaction.Result next = fixture.execute();

        assertEquals(VivecraftCoreCanaryTransaction.Outcome.TERMINAL_RESTORED, next.outcome);
        assertEquals(fixture.contract.baselineSha256,
                VivecraftCoreCanaryTransaction.sha256(fixture.layout.target));
        assertNull(next.permit);
    }

    @Test
    public void attemptingMarkerRestoresBaselineAndNeverRetries() throws Exception {
        Fixture fixture = fixture("candidate-a");
        fixture.marker.state = VivecraftCoreCanaryTransaction.STATE_ATTEMPTING;
        Files.copy(fixture.layout.candidate(RUN), fixture.layout.target,
                java.nio.file.StandardCopyOption.REPLACE_EXISTING);
        fixture.arm();

        VivecraftCoreCanaryTransaction.Result result = fixture.execute();

        assertEquals(VivecraftCoreCanaryTransaction.Outcome.TERMINAL_RESTORED, result.outcome);
        assertNull(result.permit);
        assertEquals(fixture.contract.baselineSha256,
                VivecraftCoreCanaryTransaction.sha256(fixture.layout.target));
        assertFalse(Files.exists(fixture.layout.candidate(RUN)));
        assertEquals(VivecraftCoreCanaryTransaction.STATE_ATTEMPTING,
                VivecraftCoreCanaryTransaction.readMarker(fixture.layout.marker).state);
    }

    @Test
    public void expiredMarkerRestoresBaselineAndDeletesCandidate() throws Exception {
        Fixture fixture = fixture("candidate-a");
        fixture.marker.expiresAtEpochMs = NOW - 1;
        fixture.arm();

        VivecraftCoreCanaryTransaction.Result result = fixture.execute();

        assertEquals(VivecraftCoreCanaryTransaction.Outcome.TERMINAL_RESTORED, result.outcome);
        assertEquals(VivecraftCoreCanaryTransaction.STATE_EXPIRED,
                VivecraftCoreCanaryTransaction.readMarker(fixture.layout.marker).state);
        assertFalse(Files.exists(fixture.layout.candidate(RUN)));
        assertEquals(fixture.contract.baselineSha256,
                VivecraftCoreCanaryTransaction.sha256(fixture.layout.target));
    }

    @Test
    public void unknownFieldIsQuarantinedAndCannotRetry() throws Exception {
        Fixture fixture = fixture("candidate-a");
        fixture.arm();
        String json = new String(Files.readAllBytes(fixture.layout.marker), StandardCharsets.UTF_8);
        json = json.replaceFirst("\\{", "{\n  \"surprise\": true,");
        Files.write(fixture.layout.marker, json.getBytes(StandardCharsets.UTF_8));

        VivecraftCoreCanaryTransaction.Result result = fixture.execute();

        assertEquals(VivecraftCoreCanaryTransaction.Outcome.INVALID_QUARANTINED, result.outcome);
        assertFalse(Files.exists(fixture.layout.marker));
        assertTrue(Files.exists(fixture.layout.rejectedMarker));
        assertEquals(fixture.contract.baselineSha256,
                VivecraftCoreCanaryTransaction.sha256(fixture.layout.target));
    }

    @Test
    public void duplicateMarkerFieldIsRejected() throws Exception {
        Fixture fixture = fixture("candidate-a");
        fixture.arm();
        String json = new String(Files.readAllBytes(fixture.layout.marker), StandardCharsets.UTF_8);
        json = json.replaceFirst("\\{", "{\n  \"schemaVersion\": 2,");
        Files.write(fixture.layout.marker, json.getBytes(StandardCharsets.UTF_8));

        VivecraftCoreCanaryTransaction.Result result = fixture.execute();

        assertEquals(VivecraftCoreCanaryTransaction.Outcome.INVALID_QUARANTINED, result.outcome);
        assertTrue(Files.exists(fixture.layout.rejectedMarker));
    }

    @Test
    public void unknownStateIsQuarantinedWithoutPromotion() throws Exception {
        Fixture fixture = fixture("candidate-a");
        fixture.marker.state = "retry-me";
        fixture.arm();

        VivecraftCoreCanaryTransaction.Result result = fixture.execute();

        assertEquals(VivecraftCoreCanaryTransaction.Outcome.INVALID_QUARANTINED, result.outcome);
        assertEquals(fixture.contract.baselineSha256,
                VivecraftCoreCanaryTransaction.sha256(fixture.layout.target));
    }

    @Test
    public void uppercaseRunIdAndOverlongArmWindowAreRejected() throws Exception {
        Fixture uppercase = fixture("candidate-uppercase");
        uppercase.marker.runId = RUN.toUpperCase();
        VivecraftCoreCanaryTransaction.writeMarkerAtomically(uppercase.layout, uppercase.marker);
        assertEquals(VivecraftCoreCanaryTransaction.Outcome.INVALID_QUARANTINED,
                uppercase.execute().outcome);
        removeFixture(uppercase);

        Fixture overlong = fixture("candidate-overlong");
        overlong.marker.expiresAtEpochMs = NOW + VivecraftCoreCanaryTransaction.MAX_ARM_TTL_MS + 1;
        overlong.arm();
        assertEquals(VivecraftCoreCanaryTransaction.Outcome.INVALID_QUARANTINED,
                overlong.execute().outcome);
    }

    @Test
    public void invalidRunIdCannotRedirectTheBaselineRestoreStage() throws Exception {
        Fixture fixture = fixture("candidate-invalid-run-id");
        fixture.arm();
        String json = new String(Files.readAllBytes(fixture.layout.marker),
                StandardCharsets.UTF_8).replace(RUN, "x/../../outside");
        Files.write(fixture.layout.marker, json.getBytes(StandardCharsets.UTF_8));
        Files.createDirectory(fixture.layout.target.getParent().resolve(".vivecraft-baseline-x"));
        Path outside = fixture.layout.target.getParent().getParent().resolve("outside.tmp");
        byte[] sentinel = "do-not-touch".getBytes(StandardCharsets.UTF_8);
        Files.write(outside, sentinel);

        VivecraftCoreCanaryTransaction.Result result = fixture.execute();

        assertEquals(VivecraftCoreCanaryTransaction.Outcome.INVALID_QUARANTINED,
                result.outcome);
        assertArrayEquals(sentinel, Files.readAllBytes(outside));
        assertEquals(fixture.contract.baselineSha256,
                VivecraftCoreCanaryTransaction.sha256(fixture.layout.target));
    }

    @Test
    public void trailingJsonIsRejectedBeforeAnyPromotion() throws Exception {
        Fixture fixture = fixture("candidate-a");
        fixture.arm();
        Files.write(fixture.layout.marker, " true".getBytes(StandardCharsets.UTF_8),
                java.nio.file.StandardOpenOption.APPEND);

        VivecraftCoreCanaryTransaction.Result result = fixture.execute();

        assertEquals(VivecraftCoreCanaryTransaction.Outcome.INVALID_QUARANTINED, result.outcome);
        assertEquals(fixture.contract.baselineSha256,
                VivecraftCoreCanaryTransaction.sha256(fixture.layout.target));
    }

    @Test
    public void missingMistypedAndNonOneShotMarkerFieldsAreRejected() throws Exception {
        Fixture missing = fixture("candidate-missing");
        missing.arm();
        String missingJson = new String(Files.readAllBytes(missing.layout.marker),
                StandardCharsets.UTF_8).replaceFirst(
                "(?m)^  \\\"fabricId\\\": \\\"vivecraft\\\",\\R", "");
        Files.write(missing.layout.marker, missingJson.getBytes(StandardCharsets.UTF_8));
        assertEquals(VivecraftCoreCanaryTransaction.Outcome.INVALID_QUARANTINED,
                missing.execute().outcome);
        removeFixture(missing);

        Fixture mistyped = fixture("candidate-mistyped");
        mistyped.arm();
        String mistypedJson = new String(Files.readAllBytes(mistyped.layout.marker),
                StandardCharsets.UTF_8).replaceFirst(
                "\\\"schemaVersion\\\": 2", "\\\"schemaVersion\\\": \\\"2\\\"");
        Files.write(mistyped.layout.marker, mistypedJson.getBytes(StandardCharsets.UTF_8));
        assertEquals(VivecraftCoreCanaryTransaction.Outcome.INVALID_QUARANTINED,
                mistyped.execute().outcome);
        removeFixture(mistyped);

        Fixture repeated = fixture("candidate-retry-count");
        repeated.marker.maxLaunches = 2;
        repeated.arm();
        assertEquals(VivecraftCoreCanaryTransaction.Outcome.INVALID_QUARANTINED,
                repeated.execute().outcome);
    }

    @Test
    public void copyBatchModeIsExactRequiredAndPreservedInPermit() throws Exception {
        Fixture enabled = fixture("candidate-enabled");
        enabled.marker.openXrCopyBatchMode = VivecraftCoreCanaryTransaction.OPENXR_COPY_BATCH_ON;
        enabled.arm();

        VivecraftCoreCanaryTransaction.Result promoted = enabled.execute();

        assertEquals(VivecraftCoreCanaryTransaction.Outcome.PROMOTED, promoted.outcome);
        assertEquals(VivecraftCoreCanaryTransaction.OPENXR_COPY_BATCH_ON,
                promoted.permit.openXrCopyBatchMode);
        assertEquals(VivecraftCoreCanaryTransaction.OPENXR_COPY_BATCH_ON,
                VivecraftCoreCanaryTransaction.readMarker(enabled.layout.marker).openXrCopyBatchMode);
        removeFixture(enabled);

        for(String invalid : new String[]{"on", "OFF ", "-Dvivecraft.openxrCopyBatch=ON"}) {
            Fixture rejected = fixture("candidate-invalid-mode-" + invalid.length());
            rejected.marker.openXrCopyBatchMode = invalid;
            rejected.arm();
            assertEquals(invalid, VivecraftCoreCanaryTransaction.Outcome.INVALID_QUARANTINED,
                    rejected.execute().outcome);
            assertEquals(invalid, rejected.contract.baselineSha256,
                    VivecraftCoreCanaryTransaction.sha256(rejected.layout.target));
            removeFixture(rejected);
        }

        Fixture missing = fixture("candidate-missing-mode");
        missing.arm();
        String missingJson = new String(Files.readAllBytes(missing.layout.marker),
                StandardCharsets.UTF_8).replaceFirst(
                "(?m)^  \\\"openXrCopyBatchMode\\\": \\\"OFF\\\",\\R", "");
        Files.write(missing.layout.marker, missingJson.getBytes(StandardCharsets.UTF_8));
        assertEquals(VivecraftCoreCanaryTransaction.Outcome.INVALID_QUARANTINED,
                missing.execute().outcome);
        removeFixture(missing);

        Fixture oldSchema = fixture("candidate-old-schema");
        oldSchema.arm();
        String oldJson = new String(Files.readAllBytes(oldSchema.layout.marker),
                StandardCharsets.UTF_8).replaceFirst(
                "\\\"schemaVersion\\\": 2", "\\\"schemaVersion\\\": 1");
        Files.write(oldSchema.layout.marker, oldJson.getBytes(StandardCharsets.UTF_8));
        assertEquals(VivecraftCoreCanaryTransaction.Outcome.INVALID_QUARANTINED,
                oldSchema.execute().outcome);
    }

    @Test
    public void wrongOtherModFingerprintConsumesNoLaunch() throws Exception {
        Fixture fixture = fixture("candidate-a");
        fixture.marker.otherModsFingerprintSha256 = "f".repeat(64);
        fixture.arm();

        VivecraftCoreCanaryTransaction.Result result = fixture.execute();

        assertEquals(VivecraftCoreCanaryTransaction.Outcome.INVALID_QUARANTINED, result.outcome);
        assertNull(result.permit);
        assertEquals(fixture.contract.baselineSha256,
                VivecraftCoreCanaryTransaction.sha256(fixture.layout.target));
    }

    @Test
    public void candidateMetadataMustMatchMarkerExactly() throws Exception {
        Fixture fixture = fixture("candidate-a");
        fixture.marker.fabricVersion = "wrong-version";
        fixture.arm();

        VivecraftCoreCanaryTransaction.Result result = fixture.execute();

        assertEquals(VivecraftCoreCanaryTransaction.Outcome.FAILED, result.outcome);
        assertFalse(Files.exists(fixture.layout.marker));
        assertTrue(Files.exists(fixture.layout.rejectedMarker));
        assertEquals(fixture.contract.baselineSha256,
                VivecraftCoreCanaryTransaction.sha256(fixture.layout.target));
    }

    @Test
    public void pathTraversalEntryIsRejectedBeforePromotion() throws Exception {
        Fixture fixture = fixture("candidate-a");
        writeJar(fixture.layout.candidate(RUN), "candidate-a", "../escape.class");
        fixture.refreshCandidateLock();
        fixture.arm();

        VivecraftCoreCanaryTransaction.Result result = fixture.execute();

        assertEquals(VivecraftCoreCanaryTransaction.Outcome.FAILED, result.outcome);
        assertEquals(fixture.contract.baselineSha256,
                VivecraftCoreCanaryTransaction.sha256(fixture.layout.target));
    }

    @Test
    public void caseCollidingDuplicateEntriesAreRejected() throws Exception {
        Fixture fixture = fixture("candidate-a");
        writeJar(fixture.layout.candidate(RUN), "candidate-a", "data/A.class", "data/a.class");
        fixture.refreshCandidateLock();
        fixture.arm();

        VivecraftCoreCanaryTransaction.Result result = fixture.execute();

        assertEquals(VivecraftCoreCanaryTransaction.Outcome.FAILED, result.outcome);
        assertEquals(fixture.contract.baselineSha256,
                VivecraftCoreCanaryTransaction.sha256(fixture.layout.target));
    }

    @Test
    public void unixSymlinkEntryIsRejected() throws Exception {
        Fixture fixture = fixture("candidate-a");
        Path candidate = fixture.layout.candidate(RUN);
        writeJar(candidate, "candidate-a", "data/link");
        markCentralEntryAsSymlink(candidate, "data/link");
        fixture.refreshCandidateLock();
        fixture.arm();

        VivecraftCoreCanaryTransaction.Result result = fixture.execute();

        assertEquals(VivecraftCoreCanaryTransaction.Outcome.FAILED, result.outcome);
        assertEquals(fixture.contract.baselineSha256,
                VivecraftCoreCanaryTransaction.sha256(fixture.layout.target));
    }

    @Test
    public void everyInjectedTransactionFailureRestoresBaselineAndPublishesNoPermit()
            throws Exception {
        for(VivecraftCoreCanaryTransaction.Stage stage :
                VivecraftCoreCanaryTransaction.Stage.values()) {
            Fixture fixture = fixture("candidate-" + stage.name());
            fixture.arm();
            VivecraftCoreCanaryTransaction.Result result =
                    VivecraftCoreCanaryTransaction.execute(fixture.layout, fixture.contract, current -> {
                        if(current == stage) {
                            throw new IOException("injected-" + current);
                        }
                    });
            assertEquals(stage.name(), VivecraftCoreCanaryTransaction.Outcome.FAILED, result.outcome);
            assertNull(stage.name(), result.permit);
            assertEquals(stage.name(), fixture.contract.baselineSha256,
                    VivecraftCoreCanaryTransaction.sha256(fixture.layout.target));
            assertFalse(stage.name(), Files.exists(fixture.layout.candidate(RUN)));
            if(stage == VivecraftCoreCanaryTransaction.Stage.VALIDATED) {
                assertTrue(stage.name(), Files.exists(fixture.layout.rejectedMarker));
            } else {
                assertEquals(stage.name(), VivecraftCoreCanaryTransaction.STATE_CONSUMED,
                        VivecraftCoreCanaryTransaction.readMarker(fixture.layout.marker).state);
            }
            removeFixture(fixture);
        }
    }

    @Test
    public void concurrentPrelaunchCannotPromoteTwice() throws Exception {
        Fixture fixture = fixture("candidate-a");
        fixture.arm();
        CountDownLatch inside = new CountDownLatch(1);
        CountDownLatch release = new CountDownLatch(1);
        AtomicReference<VivecraftCoreCanaryTransaction.Result> first = new AtomicReference<>();
        Thread thread = new Thread(() -> first.set(VivecraftCoreCanaryTransaction.execute(
                fixture.layout, fixture.contract, stage -> {
                    if(stage == VivecraftCoreCanaryTransaction.Stage.VALIDATED) {
                        inside.countDown();
                        try {
                            if(!release.await(5, TimeUnit.SECONDS)) {
                                throw new IOException("test timeout");
                            }
                        } catch(InterruptedException e) {
                            Thread.currentThread().interrupt();
                            throw new IOException(e);
                        }
                    }
                })));
        thread.start();
        assertTrue(inside.await(5, TimeUnit.SECONDS));

        VivecraftCoreCanaryTransaction.Result second = fixture.execute();
        assertEquals(VivecraftCoreCanaryTransaction.Outcome.BUSY, second.outcome);
        release.countDown();
        thread.join(5000);
        assertFalse(thread.isAlive());
        assertEquals(VivecraftCoreCanaryTransaction.Outcome.PROMOTED, first.get().outcome);
        assertEquals(fixture.marker.candidateSha256,
                VivecraftCoreCanaryTransaction.sha256(fixture.layout.target));
    }

    @Test
    public void postPromotionVerifierFailureRestoresExactBaseline() throws Exception {
        Fixture fixture = fixture("candidate-a");
        fixture.arm();
        VivecraftCoreCanaryTransaction.Result result = fixture.execute();
        assertEquals(VivecraftCoreCanaryTransaction.Outcome.PROMOTED, result.outcome);

        assertTrue(VivecraftCoreCanaryTransaction.restoreAfterFailure(result.permit));

        assertEquals(fixture.contract.baselineSha256,
                VivecraftCoreCanaryTransaction.sha256(fixture.layout.target));
    }

    @Test
    public void otherModFingerprintIsSortedAndContentBound() throws Exception {
        Fixture fixture = fixture("candidate-a");
        Path mods = fixture.layout.target.getParent();
        Files.write(mods.resolve("z-last.jar"), new byte[]{9});
        Files.write(mods.resolve("a-first.jar"), new byte[]{1});
        String first = VivecraftCoreCanaryTransaction.fingerprintOtherMods(mods, fixture.layout.target);
        Files.delete(mods.resolve("z-last.jar"));
        Files.write(mods.resolve("z-last.jar"), new byte[]{9});
        String reordered = VivecraftCoreCanaryTransaction.fingerprintOtherMods(mods, fixture.layout.target);
        assertEquals(first, reordered);
        Files.write(mods.resolve("z-last.jar"), new byte[]{8});
        assertFalse(first.equals(VivecraftCoreCanaryTransaction.fingerprintOtherMods(
                mods, fixture.layout.target)));
    }

    @Test
    public void exactCandidateAllowlistRejectsEveryOtherHashBeforePromotion() throws Exception {
        Fixture fixture = fixture("candidate-not-approved");
        fixture.arm();
        VivecraftCoreCanaryTransaction.Contract strict =
                new VivecraftCoreCanaryTransaction.Contract(
                        HARNESS, PACKAGE, PROFILE, TARGET,
                        fixture.contract.baselineSha256, fixture.contract.baselineSizeBytes,
                        fixture.contract.otherModsFingerprintSha256, NOW,
                        "vivecraft", "26.2.x", ">=25",
                        Collections.singleton("a".repeat(64)));

        VivecraftCoreCanaryTransaction.Result result =
                VivecraftCoreCanaryTransaction.execute(
                        fixture.layout, strict, VivecraftCoreCanaryTransaction.NO_FAULTS);

        assertEquals(VivecraftCoreCanaryTransaction.Outcome.INVALID_QUARANTINED,
                result.outcome);
        assertEquals(fixture.contract.baselineSha256,
                VivecraftCoreCanaryTransaction.sha256(fixture.layout.target));
    }

    @Test
    public void exactCandidateAllowlistPromotesTheMatchingHash() throws Exception {
        Fixture fixture = fixture("candidate-approved");
        fixture.arm();
        VivecraftCoreCanaryTransaction.Contract strict =
                new VivecraftCoreCanaryTransaction.Contract(
                        HARNESS, PACKAGE, PROFILE, TARGET,
                        fixture.contract.baselineSha256, fixture.contract.baselineSizeBytes,
                        fixture.contract.otherModsFingerprintSha256, NOW,
                        "vivecraft", "26.2.x", ">=25",
                        Collections.singleton(fixture.marker.candidateSha256));

        VivecraftCoreCanaryTransaction.Result result =
                VivecraftCoreCanaryTransaction.execute(
                        fixture.layout, strict, VivecraftCoreCanaryTransaction.NO_FAULTS);

        assertEquals(VivecraftCoreCanaryTransaction.Outcome.PROMOTED, result.outcome);
        assertEquals(fixture.marker.candidateSha256,
                VivecraftCoreCanaryTransaction.sha256(fixture.layout.target));
    }

    @Test
    public void emptyCandidateAllowlistRejectsAllCandidates() throws Exception {
        Fixture fixture = fixture("candidate-empty-list");
        fixture.arm();
        VivecraftCoreCanaryTransaction.Contract strict =
                new VivecraftCoreCanaryTransaction.Contract(
                        HARNESS, PACKAGE, PROFILE, TARGET,
                        fixture.contract.baselineSha256, fixture.contract.baselineSizeBytes,
                        fixture.contract.otherModsFingerprintSha256, NOW,
                        "vivecraft", "26.2.x", ">=25", Collections.emptySet());

        VivecraftCoreCanaryTransaction.Result result =
                VivecraftCoreCanaryTransaction.execute(
                        fixture.layout, strict, VivecraftCoreCanaryTransaction.NO_FAULTS);

        assertEquals(VivecraftCoreCanaryTransaction.Outcome.INVALID_QUARANTINED,
                result.outcome);
    }

    @Test
    public void exactFabricVersionContractRejectsAHashAllowedCandidate() throws Exception {
        Fixture fixture = fixture("candidate-version-mismatch");
        fixture.arm();
        VivecraftCoreCanaryTransaction.Contract strict =
                new VivecraftCoreCanaryTransaction.Contract(
                        HARNESS, PACKAGE, PROFILE, TARGET,
                        fixture.contract.baselineSha256, fixture.contract.baselineSizeBytes,
                        fixture.contract.otherModsFingerprintSha256, NOW,
                        "vivecraft", "not-the-candidate-version", "26.2.x", ">=25",
                        Collections.singleton(fixture.marker.candidateSha256));

        VivecraftCoreCanaryTransaction.Result result =
                VivecraftCoreCanaryTransaction.execute(
                        fixture.layout, strict, VivecraftCoreCanaryTransaction.NO_FAULTS);

        assertEquals(VivecraftCoreCanaryTransaction.Outcome.INVALID_QUARANTINED,
                result.outcome);
    }

    private Fixture fixture(String candidatePayload) throws Exception {
        Path fixtureRoot = root.resolve("fixture-" + System.nanoTime());
        Path game = fixtureRoot.resolve("instances/26.2");
        Path mods = game.resolve("mods");
        Path state = game.resolve(".questcraft/" + HARNESS);
        Files.createDirectories(mods);
        Files.createDirectories(state);
        Path baseline = fixtureRoot.resolve("baseline-input.jar");
        writeJar(baseline, "baseline");
        Path target = mods.resolve("Vivecraft.jar");
        Files.copy(baseline, target);
        Path other = mods.resolve("Fabric-API.jar");
        Files.write(other, new byte[]{1, 2, 3});
        VivecraftCoreCanaryTransaction.Layout layout =
                new VivecraftCoreCanaryTransaction.Layout(state, target);
        Files.copy(baseline, layout.baselineSource);
        Path candidate = layout.candidate(RUN);
        writeJar(candidate, candidatePayload);
        String fingerprint = VivecraftCoreCanaryTransaction.fingerprintOtherMods(mods, target);
        VivecraftCoreCanaryTransaction.Contract contract =
                new VivecraftCoreCanaryTransaction.Contract(
                        HARNESS, PACKAGE, PROFILE, TARGET,
                        VivecraftCoreCanaryTransaction.sha256(baseline), Files.size(baseline),
                        fingerprint, NOW);
        VivecraftCoreCanaryTransaction.Marker marker = marker(candidate, contract);
        return new Fixture(fixtureRoot, layout, contract, marker);
    }

    private static VivecraftCoreCanaryTransaction.Marker marker(
            Path candidate, VivecraftCoreCanaryTransaction.Contract contract) throws Exception {
        VivecraftCoreCanaryTransaction.Marker marker = new VivecraftCoreCanaryTransaction.Marker();
        marker.schemaVersion = VivecraftCoreCanaryTransaction.SCHEMA_VERSION;
        marker.harnessId = HARNESS;
        marker.state = VivecraftCoreCanaryTransaction.STATE_ARMED;
        marker.packageName = PACKAGE;
        marker.profile = PROFILE;
        marker.target = TARGET;
        marker.runId = RUN;
        marker.baselineSha256 = contract.baselineSha256;
        marker.baselineSizeBytes = contract.baselineSizeBytes;
        marker.candidateSha256 = VivecraftCoreCanaryTransaction.sha256(candidate);
        marker.candidateSizeBytes = Files.size(candidate);
        marker.fabricId = "vivecraft";
        marker.fabricVersion = "26.2-1.3.15";
        marker.minecraftDependency = "26.2.x";
        marker.javaDependency = ">=25";
        marker.otherModsFingerprintSha256 = contract.otherModsFingerprintSha256;
        marker.openXrCopyBatchMode = VivecraftCoreCanaryTransaction.OPENXR_COPY_BATCH_OFF;
        marker.expiresAtEpochMs = NOW + TimeUnit.MINUTES.toMillis(15);
        marker.maxLaunches = 1;
        return marker;
    }

    private static void writeJar(Path path, String payload, String... extraNames) throws Exception {
        Files.createDirectories(path.getParent());
        try(ZipOutputStream output = new ZipOutputStream(Files.newOutputStream(path))) {
            add(output, "fabric.mod.json", ("{\"schemaVersion\":1,\"id\":\"vivecraft\"," +
                    "\"version\":\"26.2-1.3.15\",\"depends\":{" +
                    "\"minecraft\":[\"26.2.x\"],\"java\":\">=25\"}}").getBytes(StandardCharsets.UTF_8));
            add(output, "payload.txt", payload.getBytes(StandardCharsets.UTF_8));
            for(String name : extraNames) {
                add(output, name, name.getBytes(StandardCharsets.UTF_8));
            }
        }
    }

    private static void add(ZipOutputStream output, String name, byte[] bytes) throws Exception {
        output.putNextEntry(new ZipEntry(name));
        output.write(bytes);
        output.closeEntry();
    }

    private static void markCentralEntryAsSymlink(Path archive, String entryName) throws Exception {
        byte[] bytes = Files.readAllBytes(archive);
        ByteBuffer view = ByteBuffer.wrap(bytes).order(ByteOrder.LITTLE_ENDIAN);
        byte[] expected = entryName.getBytes(StandardCharsets.UTF_8);
        for(int cursor = 0; cursor <= bytes.length - 46; cursor++) {
            if((view.getInt(cursor) & 0xffffffffL) != 0x02014b50L) {
                continue;
            }
            int nameLength = view.getShort(cursor + 28) & 0xffff;
            if(nameLength == expected.length && cursor + 46 + nameLength <= bytes.length) {
                byte[] actual = Arrays.copyOfRange(bytes, cursor + 46, cursor + 46 + nameLength);
                if(Arrays.equals(expected, actual)) {
                    view.putShort(cursor + 4, (short)0x0314);
                    view.putInt(cursor + 38, (0120777 << 16));
                    Files.write(archive, bytes);
                    return;
                }
            }
        }
        throw new IOException("central entry not found");
    }

    private static void removeFixture(Fixture fixture) throws Exception {
        if(Files.exists(fixture.root)) {
            Files.walk(fixture.root)
                    .sorted((left, right) -> right.getNameCount() - left.getNameCount())
                    .forEach(path -> {
                        try {
                            Files.deleteIfExists(path);
                        } catch(IOException e) {
                            throw new RuntimeException(e);
                        }
                    });
        }
    }

    private static final class Fixture {
        final Path root;
        final VivecraftCoreCanaryTransaction.Layout layout;
        final VivecraftCoreCanaryTransaction.Contract contract;
        final VivecraftCoreCanaryTransaction.Marker marker;

        Fixture(Path root, VivecraftCoreCanaryTransaction.Layout layout,
                VivecraftCoreCanaryTransaction.Contract contract,
                VivecraftCoreCanaryTransaction.Marker marker) {
            this.root = root;
            this.layout = layout;
            this.contract = contract;
            this.marker = marker;
        }

        void arm() throws Exception {
            VivecraftCoreCanaryTransaction.writeMarkerAtomically(layout, marker);
        }

        void refreshCandidateLock() throws Exception {
            Path candidate = layout.candidate(RUN);
            marker.candidateSha256 = VivecraftCoreCanaryTransaction.sha256(candidate);
            marker.candidateSizeBytes = Files.size(candidate);
        }

        VivecraftCoreCanaryTransaction.Result execute() {
            return VivecraftCoreCanaryTransaction.execute(
                    layout, contract, VivecraftCoreCanaryTransaction.NO_FAULTS);
        }
    }
}
