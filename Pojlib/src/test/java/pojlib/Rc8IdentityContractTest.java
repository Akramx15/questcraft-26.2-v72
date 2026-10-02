package pojlib;

import com.google.gson.JsonElement;
import com.google.gson.JsonObject;
import com.google.gson.JsonParser;
import org.junit.Test;

import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertNotNull;
import static org.junit.Assert.assertTrue;

/** Source-level guard for the persistent, Lab-only RC8 identity. */
public class Rc8IdentityContractTest {
    private static final Path ROOT = Path.of("..");
    private static final String VERSION =
            "6.0.1-26.2-vivecraft-personal.12-rc.8";
    private static final String CORE_VERSION = "26.2-1.3.15+qc.v71.rc8-mining";
    private static final String CORE_SHA256 =
            "ADDB01FA168033C42F97C615DAF97CBB927B9E94400606EEF27CFBE930015EAB";
    private static final String VEQ_VERSION = "0.7.0-v71.rc6";
    private static final String VEQ_SHA256 =
            "FF7F6FCFDA21895764B69F3316CE7E9EBD8D890DF675C1E8007835B3814573F9";

    @Test
    public void rc8BuilderIsExactLabOnlyAndDebugOnly() throws Exception {
        String builder = read(
                "QCXR-XR-Wrapper/Assets/Editor/QuestCraftV71Rc8LabCliBuild.cs");

        assertTrue(builder.contains(
                "ApplicationIdentifier = \"com.qcxr.qcxr.canary262\""));
        assertTrue(builder.contains("VersionName = \"" + VERSION + "\""));
        assertTrue(builder.contains("VersionCode = \"71\""));
        assertTrue(builder.contains(
                "Builds/QuestCraft-Vivecraft-Lab-26.2-v71-rc.8-mining-local.apk"));
        assertTrue(builder.contains("HasArgument(\"-release\")"));
        assertTrue(builder.contains("QuestCraftCliBuild.BuildAndroid();"));
        assertFalse(builder.contains("com.qcxr.qcxr.dev262"));
    }

    @Test
    public void rc8OwnsANewHarnessAndAllManifestsMatchExactAssets() throws Exception {
        String gate = read("Pojlib/src/main/java/pojlib/VivecraftCoreCanaryGate.java");
        assertTrue(gate.contains("questcraft-vivecraft-core-canary-v9"));
        assertTrue(gate.contains(CORE_VERSION));
        assertTrue(gate.contains(CORE_SHA256.toLowerCase()));

        String expectedManagedBlock = null;
        for(String manifestPath : new String[] {
                "Pojlib/mods.json",
                "Pojlib/devmods.json",
                "Pojlib/src/main/assets/mods.json",
                "Pojlib/src/main/assets/devmods.json"}) {
            JsonObject manifest = JsonParser.parseString(read(manifestPath)).getAsJsonObject();
            JsonObject version262 = null;
            for(JsonElement versionElement : manifest.getAsJsonArray("versions")) {
                JsonObject candidate = versionElement.getAsJsonObject();
                if("26.2".equals(candidate.get("name").getAsString())) {
                    version262 = candidate;
                    break;
                }
            }
            assertNotNull(version262);
            String managedBlock = version262.getAsJsonArray("coreMods") + "\n" +
                    version262.getAsJsonArray("defaultMods");
            if(expectedManagedBlock == null) {
                expectedManagedBlock = managedBlock;
            } else {
                assertEquals(expectedManagedBlock, managedBlock);
            }

            JsonObject core = version262.getAsJsonArray("coreMods")
                    .get(0).getAsJsonObject();
            assertEquals(CORE_VERSION, core.get("version").getAsString());
            assertEquals(CORE_SHA256, core.get("sha256").getAsString());
            JsonObject veq = null;
            for(JsonElement modElement : version262.getAsJsonArray("defaultMods")) {
                JsonObject candidate = modElement.getAsJsonObject();
                if("Vivecraft-Essentials-Quest".equals(
                        candidate.get("slug").getAsString())) {
                    veq = candidate;
                    break;
                }
            }
            assertNotNull(veq);
            assertEquals(VEQ_VERSION, veq.get("version").getAsString());
            assertEquals(VEQ_SHA256, veq.get("sha256").getAsString());
        }

        Path coreAsset = ROOT.resolve(
                "Pojlib/src/main/assets/mods/vivecraft-26.2-1.3.15-quest.bin");
        assertEquals(10_078_822L, Files.size(coreAsset));
        assertEquals(CORE_SHA256,
                VivecraftCoreCanaryTransaction.sha256(coreAsset).toUpperCase());
    }

    @Test
    public void rc8IsAllowedAndVerifierRequiresItsExactDexIdentity() throws Exception {
        String policy = read("Pojlib/src/main/java/pojlib/LauncherResourceReleasePolicy.java");
        String launcher = read("QCXR-XR-Wrapper/Assets/Scripts/InstanceButton.cs");
        String verifier = read("scripts/verify-dev-apk.ps1");

        assertTrue(policy.contains("LAB_RC8_VERSION_NAME ="));
        assertTrue(policy.contains("LAB_RC8_VERSION_NAME.equals(versionName)"));
        assertTrue(policy.contains(VERSION));
        assertTrue(launcher.contains("LauncherResourceReleaseLabRc8Version ="));
        assertTrue(launcher.contains(
                "Application.version, LauncherResourceReleaseLabRc8Version"));
        assertTrue(launcher.contains(VERSION));
        assertTrue(verifier.contains("'questcraft-vivecraft-core-canary-v9'"));
        assertTrue(verifier.contains("'" + CORE_VERSION + "'"));
        assertTrue(verifier.contains("'" + CORE_SHA256.toLowerCase() + "'"));
        assertTrue(verifier.contains("'questcraft-veq-v71-canary-v5'"));
        assertTrue(verifier.contains("'" + VEQ_VERSION + "'"));
        assertTrue(verifier.contains("'" + VEQ_SHA256.toLowerCase() + "'"));
    }

    private static String read(String relative) throws Exception {
        return new String(Files.readAllBytes(ROOT.resolve(relative)), StandardCharsets.UTF_8);
    }
}
