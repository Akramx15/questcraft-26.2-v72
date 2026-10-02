package pojlib;

import org.junit.Test;

import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertTrue;

public class ModsAbCanarySourceIntegrationTest {
    private static final String LAB_PACKAGE = "com.qcxr.qcxr.canary262";
    private static final String STABLE_PACKAGE = "com.qcxr.qcxr.dev262";

    @Test
    public void gateIsFixedToLabAndExactFourExperimentAllowlist() throws Exception {
        String gate = read("src/main/java/pojlib/ModsAbCanaryGate.java");
        assertTrue(gate.contains("EXPECTED_PACKAGE = \"" + LAB_PACKAGE + "\""));
        assertTrue(!gate.contains("EXPECTED_PACKAGE = \"" + STABLE_PACKAGE + "\""));
        assertTrue(gate.contains("PROFILE = \"26.2\""));
        assertTrue(gate.contains("\"sodium-0.9.1\""));
        assertTrue(gate.contains("\"without-lithium\""));
        assertTrue(gate.contains("\"without-ferrite-core\""));
        assertTrue(gate.contains("\"without-bad-optimizations\""));
        assertTrue(gate.contains("UnattendedStackVerifier.verify(activity, instance)"));
        assertTrue(gate.contains("a6d1ced177a1c57147e8c1c8043650d5f93e1f2824c9952f3fb67ae05633a0a7"));
        assertTrue(gate.contains("de406c7a0ca5e748dfbe44740278400882a44e3109e2584b243ec02d4003344b"));

        int packageGuard = gate.indexOf(
                "if(!EXPECTED_PACKAGE.equals(activity.getPackageName()))");
        int profilePath = gate.indexOf("Paths.get(instance.gameDir)");
        int markerProbe = gate.indexOf("Files.exists(markerPath");
        assertTrue(packageGuard >= 0);
        assertTrue(profilePath > packageGuard);
        assertTrue(markerProbe > packageGuard);
    }

    @Test
    public void gateRunsAfterReconciliationAndVerifierCanRollback() throws Exception {
        String api = read("src/main/java/pojlib/API.java");
        int prelaunch = api.indexOf("public static boolean prelaunch(");
        int recovery = api.indexOf("ModsAbCanaryGate.restorePriorProcessPermit", prelaunch);
        int reconciliation = api.indexOf("instance.updateMods(activity, instances)", recovery);
        int config = api.indexOf("MinecraftInstances.CheckVivecraftConfig(instance);");
        int core = api.indexOf("VivecraftCoreCanaryGate.prepare(activity, instance)", config);
        int veq = api.indexOf("VeqCanaryGate.prepare(activity, instance)", core);
        int mods = api.indexOf("ModsAbCanaryGate.prepare(activity, instance)", veq);
        int success = api.indexOf("return true;", mods);
        assertTrue(prelaunch >= 0);
        assertTrue(recovery > prelaunch);
        assertTrue(reconciliation > recovery);
        assertTrue(config >= 0);
        assertTrue(core > config);
        assertTrue(veq > core);
        assertTrue(mods > veq);
        assertTrue(success > mods);

        String verifier = read("src/main/java/pojlib/UnattendedStackVerifier.java");
        assertTrue(verifier.contains("ModsAbCanaryGate.verifyManagedArtifact"));
        assertTrue(verifier.contains("ModsAbCanaryGate.abortPromotedCandidate()"));
        assertTrue(verifier.contains("modsAbCanaryPermitPresent && !verified"));
    }

    @Test
    public void officialSodiumMayLockExplicitlyAbsentDependencies() throws Exception {
        String transaction = read(
                "src/main/java/pojlib/VivecraftCoreCanaryTransaction.java");
        assertTrue(transaction.contains("ABSENT_DEPENDENCY = \"<absent>\""));
        assertTrue(transaction.contains("exactDependencyOrAbsent"));

        String officialStyleMetadata = "{\"id\":\"sodium\",\"version\":" +
                "\"0.9.1+mc26.2\",\"depends\":{\"fabricloader\":\">=0.16.0\"}}";
        VivecraftCoreCanaryTransaction.FabricMetadata metadata =
                VivecraftCoreCanaryTransaction.FabricMetadata.parse(
                        officialStyleMetadata.getBytes(StandardCharsets.UTF_8));
        assertEquals("sodium", metadata.id);
        assertEquals("0.9.1+mc26.2", metadata.version);
        assertEquals(VivecraftCoreCanaryTransaction.ABSENT_DEPENDENCY,
                metadata.minecraftDependency);
        assertEquals(VivecraftCoreCanaryTransaction.ABSENT_DEPENDENCY,
                metadata.javaDependency);
    }

    private static String read(String path) throws Exception {
        return new String(Files.readAllBytes(Path.of(path)), StandardCharsets.UTF_8);
    }
}
