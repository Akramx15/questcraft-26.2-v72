package pojlib;

import org.junit.After;
import org.junit.Before;
import org.junit.Test;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;

import static org.junit.Assert.assertArrayEquals;
import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertNotNull;
import static org.junit.Assert.assertNull;
import static org.junit.Assert.assertTrue;

public class ModsAbDisableTransactionTest {
    private static final String HARNESS = "questcraft-mods-ab-canary-v1";
    private static final String PACKAGE = "com.qcxr.qcxr.canary262";
    private static final String PROFILE = "26.2";
    private static final String TARGET = "mods/Lithium.jar";
    private static final String RUN = "0123456789abcdef0123456789abcdef";
    private static final long NOW = 1_800_000_000_000L;

    private Path root;

    @Before
    public void createRoot() throws Exception {
        root = Files.createTempDirectory("mods-ab-disable-");
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
    public void validDisableIsOneShotAndRestoresOnNextPrelaunch() throws Exception {
        Fixture fixture = fixture("valid");
        fixture.arm();

        ModsAbDisableTransaction.Result promoted = fixture.execute();
        assertEquals(ModsAbDisableTransaction.Outcome.PROMOTED, promoted.outcome);
        assertNotNull(promoted.permit);
        assertFalse(Files.exists(fixture.layout.target));
        assertTrue(Files.isRegularFile(fixture.held()));
        assertEquals(VivecraftCoreCanaryTransaction.STATE_CONSUMED,
                VivecraftCoreCanaryTransaction.readMarker(fixture.layout.marker).state);
        assertTrue(ModsAbDisableTransaction.permitMatchesAbsence(
                promoted.permit, fixture.layout.target,
                fixture.contract.otherModsFingerprintSha256));

        ModsAbDisableTransaction.Result next = fixture.execute();
        assertEquals(ModsAbDisableTransaction.Outcome.TERMINAL_RESTORED, next.outcome);
        assertArrayEquals(fixture.baseline, Files.readAllBytes(fixture.layout.target));
        assertFalse(Files.exists(fixture.held()));
    }

    @Test
    public void verifierFailureRestoresHeldBaselineExactly() throws Exception {
        Fixture fixture = fixture("verify-failure");
        fixture.arm();
        ModsAbDisableTransaction.Result result = fixture.execute();
        assertEquals(ModsAbDisableTransaction.Outcome.PROMOTED, result.outcome);

        assertTrue(ModsAbDisableTransaction.restoreAfterFailure(result.permit));
        assertArrayEquals(fixture.baseline, Files.readAllBytes(fixture.layout.target));
        assertFalse(Files.exists(fixture.held()));
    }

    @Test
    public void everyInjectedFailureRestoresBaselineAndPublishesNoPermit() throws Exception {
        for(ModsAbDisableTransaction.Stage stage : ModsAbDisableTransaction.Stage.values()) {
            Fixture fixture = fixture(stage.name());
            fixture.arm();
            ModsAbDisableTransaction.Result result = ModsAbDisableTransaction.execute(
                    fixture.layout, fixture.contract, current -> {
                        if(stage == current) {
                            throw new IOException("injected-" + current);
                        }
                    });
            assertEquals(stage.name(), ModsAbDisableTransaction.Outcome.FAILED, result.outcome);
            assertNull(stage.name(), result.permit);
            assertArrayEquals(stage.name(), fixture.baseline,
                    Files.readAllBytes(fixture.layout.target));
            assertFalse(stage.name(), Files.exists(fixture.held()));
            removeFixture(fixture);
        }
    }

    @Test
    public void wrongAbsenceContractIsQuarantinedWithoutRemovingMod() throws Exception {
        Fixture fixture = fixture("wrong-contract");
        fixture.marker.candidateSha256 = "f".repeat(64);
        fixture.arm();

        ModsAbDisableTransaction.Result result = fixture.execute();

        assertEquals(ModsAbDisableTransaction.Outcome.INVALID_QUARANTINED, result.outcome);
        assertArrayEquals(fixture.baseline, Files.readAllBytes(fixture.layout.target));
        assertFalse(Files.exists(fixture.layout.marker));
        assertTrue(Files.exists(fixture.layout.rejectedMarker));
    }

    @Test
    public void expiredRequestNeverRemovesBaseline() throws Exception {
        Fixture fixture = fixture("expired");
        fixture.marker.expiresAtEpochMs = NOW - 1;
        fixture.arm();

        ModsAbDisableTransaction.Result result = fixture.execute();

        assertEquals(ModsAbDisableTransaction.Outcome.TERMINAL_RESTORED, result.outcome);
        assertArrayEquals(fixture.baseline, Files.readAllBytes(fixture.layout.target));
        assertEquals(VivecraftCoreCanaryTransaction.STATE_EXPIRED,
                VivecraftCoreCanaryTransaction.readMarker(fixture.layout.marker).state);
    }

    @Test
    public void unarmedProfileIsAnExactNoOp() throws Exception {
        Fixture fixture = fixture("no-marker");
        byte[] before = Files.readAllBytes(fixture.layout.target);

        ModsAbDisableTransaction.Result result = fixture.execute();

        assertEquals(ModsAbDisableTransaction.Outcome.BASELINE, result.outcome);
        assertArrayEquals(before, Files.readAllBytes(fixture.layout.target));
        assertFalse(Files.exists(fixture.held()));
    }

    private Fixture fixture(String suffix) throws Exception {
        Path fixtureRoot = Files.createDirectory(root.resolve(suffix));
        Path mods = Files.createDirectory(fixtureRoot.resolve("mods"));
        Path state = Files.createDirectories(
                fixtureRoot.resolve(".questcraft").resolve(HARNESS));
        Path target = mods.resolve("Lithium.jar");
        byte[] baseline = ("exact-lithium-baseline-" + suffix)
                .getBytes(StandardCharsets.UTF_8);
        Files.write(target, baseline);
        Files.write(mods.resolve("Sodium.jar"), "fixed-sodium".getBytes(StandardCharsets.UTF_8));
        VivecraftCoreCanaryTransaction.Layout layout =
                new VivecraftCoreCanaryTransaction.Layout(state, target);
        Files.write(layout.baselineSource, baseline);
        String hash = VivecraftCoreCanaryTransaction.sha256(target);
        String fingerprint = VivecraftCoreCanaryTransaction.fingerprintOtherMods(mods, target);
        ModsAbDisableTransaction.Contract contract = new ModsAbDisableTransaction.Contract(
                HARNESS, PACKAGE, PROFILE, TARGET, "lithium", hash, baseline.length,
                fingerprint, NOW);
        VivecraftCoreCanaryTransaction.Marker marker =
                new VivecraftCoreCanaryTransaction.Marker();
        marker.schemaVersion = VivecraftCoreCanaryTransaction.SCHEMA_VERSION;
        marker.harnessId = HARNESS;
        marker.state = VivecraftCoreCanaryTransaction.STATE_ARMED;
        marker.packageName = PACKAGE;
        marker.profile = PROFILE;
        marker.target = TARGET;
        marker.runId = RUN;
        marker.baselineSha256 = hash;
        marker.baselineSizeBytes = baseline.length;
        marker.candidateSha256 = ModsAbDisableTransaction.ABSENT_SHA256;
        marker.candidateSizeBytes = 0;
        marker.fabricId = "lithium";
        marker.fabricVersion = ModsAbDisableTransaction.ABSENT_VALUE;
        marker.minecraftDependency = ModsAbDisableTransaction.ABSENT_VALUE;
        marker.javaDependency = ModsAbDisableTransaction.ABSENT_VALUE;
        marker.otherModsFingerprintSha256 = fingerprint;
        marker.openXrCopyBatchMode = VivecraftCoreCanaryTransaction.OPENXR_COPY_BATCH_OFF;
        marker.expiresAtEpochMs = NOW + 60_000;
        marker.maxLaunches = 1;
        return new Fixture(layout, contract, marker, baseline);
    }

    private void removeFixture(Fixture fixture) throws Exception {
        Path fixtureRoot = fixture.layout.stateDirectory.getParent().getParent();
        if(Files.exists(fixtureRoot)) {
            Files.walk(fixtureRoot)
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
        final VivecraftCoreCanaryTransaction.Layout layout;
        final ModsAbDisableTransaction.Contract contract;
        final VivecraftCoreCanaryTransaction.Marker marker;
        final byte[] baseline;

        Fixture(VivecraftCoreCanaryTransaction.Layout layout,
                ModsAbDisableTransaction.Contract contract,
                VivecraftCoreCanaryTransaction.Marker marker, byte[] baseline) {
            this.layout = layout;
            this.contract = contract;
            this.marker = marker;
            this.baseline = baseline;
        }

        void arm() throws Exception {
            VivecraftCoreCanaryTransaction.writeMarkerAtomically(layout, marker);
        }

        ModsAbDisableTransaction.Result execute() {
            return ModsAbDisableTransaction.execute(
                    layout, contract, ModsAbDisableTransaction.NO_FAULTS);
        }

        Path held() {
            return layout.stateDirectory.resolve("disabled-" + RUN + ".jar");
        }
    }
}
