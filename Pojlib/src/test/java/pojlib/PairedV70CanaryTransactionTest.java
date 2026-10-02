package pojlib;

import org.junit.Rule;
import org.junit.Test;
import org.junit.rules.TemporaryFolder;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.zip.ZipEntry;
import java.util.zip.ZipOutputStream;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertTrue;

public class PairedV70CanaryTransactionTest {
    private static final String PACKAGE = "com.qcxr.qcxr.canary262";
    private static final String PROFILE = "26.2";
    private static final long NOW = 1_800_000_000_000L;

    @Rule
    public final TemporaryFolder temporary = new TemporaryFolder();

    @Test
    public void pairedFingerprintExcludesOnlyCoreAndVeq() throws Exception {
        Path mods = temporary.newFolder("fingerprint-mods").toPath();
        Path core = mods.resolve("Vivecraft.jar");
        Path veq = mods.resolve("Vivecraft-Essentials-Quest.jar");
        Path other = mods.resolve("Fabric-API.jar");
        Files.write(core, new byte[]{1});
        Files.write(veq, new byte[]{2});
        Files.write(other, new byte[]{3});

        String initial = VivecraftCoreCanaryTransaction.fingerprintOtherMods(mods, core, veq);
        Files.write(core, new byte[]{4});
        Files.write(veq, new byte[]{5});
        assertEquals(initial,
                VivecraftCoreCanaryTransaction.fingerprintOtherMods(mods, core, veq));

        Files.write(other, new byte[]{6});
        assertFalse(initial.equals(
                VivecraftCoreCanaryTransaction.fingerprintOtherMods(mods, core, veq)));
    }

    @Test
    public void bothCandidatesPromoteAndPermitsRemainBoundToTheSurroundingStack()
            throws Exception {
        Fixture fixture = fixture("pair-success");

        VivecraftCoreCanaryTransaction.Result core = fixture.executeCore(
                VivecraftCoreCanaryTransaction.NO_FAULTS);
        VivecraftCoreCanaryTransaction.Result veq = fixture.executeVeq(
                VivecraftCoreCanaryTransaction.NO_FAULTS);

        assertEquals(VivecraftCoreCanaryTransaction.Outcome.PROMOTED, core.outcome);
        assertEquals(VivecraftCoreCanaryTransaction.Outcome.PROMOTED, veq.outcome);
        String fingerprint = fixture.pairedFingerprint();
        assertTrue(VivecraftCoreCanaryTransaction.permitMatches(
                core.permit, fixture.core.target,
                VivecraftCoreCanaryTransaction.sha256(fixture.core.target),
                Files.size(fixture.core.target), fingerprint));
        assertTrue(VivecraftCoreCanaryTransaction.permitMatches(
                veq.permit, fixture.veq.target,
                VivecraftCoreCanaryTransaction.sha256(fixture.veq.target),
                Files.size(fixture.veq.target), fingerprint));
        assertTrue(VivecraftCoreCanaryTransaction.restoreAfterFailure(veq.permit));
        assertTrue(VivecraftCoreCanaryTransaction.restoreAfterFailure(core.permit));
        fixture.assertBaselines();
    }

    @Test
    public void eitherMarkerCanRunAloneWithoutChangingItsPeer() throws Exception {
        Fixture coreOnly = fixture("core-only");
        String veqBaseline = VivecraftCoreCanaryTransaction.sha256(coreOnly.veq.target);
        VivecraftCoreCanaryTransaction.Result core = coreOnly.executeCore(
                VivecraftCoreCanaryTransaction.NO_FAULTS);
        assertEquals(VivecraftCoreCanaryTransaction.Outcome.PROMOTED, core.outcome);
        assertEquals(veqBaseline, VivecraftCoreCanaryTransaction.sha256(coreOnly.veq.target));
        assertTrue(VivecraftCoreCanaryTransaction.restoreAfterFailure(core.permit));
        coreOnly.assertBaselines();

        Fixture veqOnly = fixture("veq-only");
        String coreBaseline = VivecraftCoreCanaryTransaction.sha256(veqOnly.core.target);
        VivecraftCoreCanaryTransaction.Result veq = veqOnly.executeVeq(
                VivecraftCoreCanaryTransaction.NO_FAULTS);
        assertEquals(VivecraftCoreCanaryTransaction.Outcome.PROMOTED, veq.outcome);
        assertEquals(coreBaseline, VivecraftCoreCanaryTransaction.sha256(veqOnly.core.target));
        assertTrue(VivecraftCoreCanaryTransaction.restoreAfterFailure(veq.permit));
        veqOnly.assertBaselines();
    }

    @Test
    public void secondPromotionFailureCanCompensateTheAlreadyPromotedCore() throws Exception {
        Fixture fixture = fixture("pair-partial-failure");
        VivecraftCoreCanaryTransaction.Result core = fixture.executeCore(
                VivecraftCoreCanaryTransaction.NO_FAULTS);
        assertEquals(VivecraftCoreCanaryTransaction.Outcome.PROMOTED, core.outcome);

        VivecraftCoreCanaryTransaction.Result veq = fixture.executeVeq(stage -> {
            if(stage == VivecraftCoreCanaryTransaction.Stage.CANDIDATE_PROMOTED) {
                throw new IOException("injected second-target failure");
            }
        });

        assertEquals(VivecraftCoreCanaryTransaction.Outcome.FAILED, veq.outcome);
        assertTrue(VivecraftCoreCanaryTransaction.restoreAfterFailure(core.permit));
        fixture.assertBaselines();
    }

    private Fixture fixture(String name) throws Exception {
        Path game = temporary.newFolder(name).toPath().resolve("instances/26.2");
        Path mods = game.resolve("mods");
        Files.createDirectories(mods);
        Path coreTarget = mods.resolve("Vivecraft.jar");
        Path veqTarget = mods.resolve("Vivecraft-Essentials-Quest.jar");
        writeJar(coreTarget, "vivecraft", "26.2-1.3.15", "26.2.x", "core-baseline");
        writeJar(veqTarget, "vivecraft_essentials_quest", "0.7.0", "26.2", "veq-baseline");
        Files.write(mods.resolve("Fabric-API.jar"), new byte[]{7, 8, 9});

        VivecraftCoreCanaryTransaction.Layout core = new VivecraftCoreCanaryTransaction.Layout(
                game.resolve(".questcraft/core"), coreTarget);
        VivecraftCoreCanaryTransaction.Layout veq = new VivecraftCoreCanaryTransaction.Layout(
                game.resolve(".questcraft/veq"), veqTarget);
        Files.createDirectories(core.stateDirectory);
        Files.createDirectories(veq.stateDirectory);
        Files.copy(coreTarget, core.baselineSource);
        Files.copy(veqTarget, veq.baselineSource);
        String coreRun = "1".repeat(32);
        String veqRun = "2".repeat(32);
        writeJar(core.candidate(coreRun), "vivecraft", "26.2-v70-canary", "26.2.x",
                "core-candidate");
        writeJar(veq.candidate(veqRun), "vivecraft_essentials_quest",
                "0.7.0-v70-canary.1", "26.2", "veq-candidate");

        String fingerprint = VivecraftCoreCanaryTransaction.fingerprintOtherMods(
                mods, coreTarget, veqTarget);
        VivecraftCoreCanaryTransaction.Contract coreContract =
                new VivecraftCoreCanaryTransaction.Contract(
                        "core", PACKAGE, PROFILE, "mods/Vivecraft.jar",
                        VivecraftCoreCanaryTransaction.sha256(core.baselineSource),
                        Files.size(core.baselineSource), fingerprint, NOW,
                        "vivecraft", null, "26.2.x", ">=25", null);
        VivecraftCoreCanaryTransaction.Contract veqContract =
                new VivecraftCoreCanaryTransaction.Contract(
                        "veq", PACKAGE, PROFILE, "mods/Vivecraft-Essentials-Quest.jar",
                        VivecraftCoreCanaryTransaction.sha256(veq.baselineSource),
                        Files.size(veq.baselineSource), fingerprint, NOW,
                        "vivecraft_essentials_quest", "0.7.0-v70-canary.1",
                        "26.2", ">=25", null);
        VivecraftCoreCanaryTransaction.writeMarkerAtomically(
                core, marker(core, coreContract, coreRun, "vivecraft", "26.2-v70-canary",
                        "26.2.x"));
        VivecraftCoreCanaryTransaction.writeMarkerAtomically(
                veq, marker(veq, veqContract, veqRun, "vivecraft_essentials_quest",
                        "0.7.0-v70-canary.1", "26.2"));
        return new Fixture(mods, core, veq, coreContract, veqContract);
    }

    private static VivecraftCoreCanaryTransaction.Marker marker(
            VivecraftCoreCanaryTransaction.Layout layout,
            VivecraftCoreCanaryTransaction.Contract contract, String runId,
            String fabricId, String fabricVersion, String minecraft) throws Exception {
        Path candidate = layout.candidate(runId);
        VivecraftCoreCanaryTransaction.Marker marker = new VivecraftCoreCanaryTransaction.Marker();
        marker.schemaVersion = VivecraftCoreCanaryTransaction.SCHEMA_VERSION;
        marker.harnessId = contract.harnessId;
        marker.state = VivecraftCoreCanaryTransaction.STATE_ARMED;
        marker.packageName = PACKAGE;
        marker.profile = PROFILE;
        marker.target = contract.target;
        marker.runId = runId;
        marker.baselineSha256 = contract.baselineSha256;
        marker.baselineSizeBytes = contract.baselineSizeBytes;
        marker.candidateSha256 = VivecraftCoreCanaryTransaction.sha256(candidate);
        marker.candidateSizeBytes = Files.size(candidate);
        marker.fabricId = fabricId;
        marker.fabricVersion = fabricVersion;
        marker.minecraftDependency = minecraft;
        marker.javaDependency = ">=25";
        marker.otherModsFingerprintSha256 = contract.otherModsFingerprintSha256;
        marker.openXrCopyBatchMode = VivecraftCoreCanaryTransaction.OPENXR_COPY_BATCH_OFF;
        marker.expiresAtEpochMs = NOW + 60_000L;
        marker.maxLaunches = 1;
        return marker;
    }

    private static void writeJar(Path path, String id, String version, String minecraft,
                                 String payload) throws Exception {
        Files.createDirectories(path.getParent());
        try(ZipOutputStream output = new ZipOutputStream(Files.newOutputStream(path))) {
            String metadata = "{\"schemaVersion\":1,\"id\":\"" + id +
                    "\",\"version\":\"" + version + "\",\"depends\":{" +
                    "\"minecraft\":\"" + minecraft + "\",\"java\":\">=25\"}}";
            add(output, "fabric.mod.json", metadata.getBytes(StandardCharsets.UTF_8));
            add(output, "payload.txt", payload.getBytes(StandardCharsets.UTF_8));
        }
    }

    private static void add(ZipOutputStream output, String name, byte[] bytes) throws Exception {
        output.putNextEntry(new ZipEntry(name));
        output.write(bytes);
        output.closeEntry();
    }

    private static final class Fixture {
        final Path mods;
        final VivecraftCoreCanaryTransaction.Layout core;
        final VivecraftCoreCanaryTransaction.Layout veq;
        final VivecraftCoreCanaryTransaction.Contract coreContract;
        final VivecraftCoreCanaryTransaction.Contract veqContract;

        Fixture(Path mods, VivecraftCoreCanaryTransaction.Layout core,
                VivecraftCoreCanaryTransaction.Layout veq,
                VivecraftCoreCanaryTransaction.Contract coreContract,
                VivecraftCoreCanaryTransaction.Contract veqContract) {
            this.mods = mods;
            this.core = core;
            this.veq = veq;
            this.coreContract = coreContract;
            this.veqContract = veqContract;
        }

        VivecraftCoreCanaryTransaction.Result executeCore(
                VivecraftCoreCanaryTransaction.FaultInjector faults) {
            return VivecraftCoreCanaryTransaction.execute(core, coreContract, faults);
        }

        VivecraftCoreCanaryTransaction.Result executeVeq(
                VivecraftCoreCanaryTransaction.FaultInjector faults) {
            return VivecraftCoreCanaryTransaction.execute(veq, veqContract, faults);
        }

        String pairedFingerprint() throws Exception {
            return VivecraftCoreCanaryTransaction.fingerprintOtherMods(
                    mods, core.target, veq.target);
        }

        void assertBaselines() throws Exception {
            assertEquals(coreContract.baselineSha256,
                    VivecraftCoreCanaryTransaction.sha256(core.target));
            assertEquals(veqContract.baselineSha256,
                    VivecraftCoreCanaryTransaction.sha256(veq.target));
        }
    }
}
