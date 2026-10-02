package pojlib;

import org.junit.Test;

import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;

import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertTrue;

/** Source-level guard for the Pojlib-only RC6.1 Lab identity. */
public class Rc61IdentityContractTest {
    private static final Path ROOT = Path.of("..");
    private static final String VERSION =
            "6.0.1-26.2-vivecraft-personal.12-rc.6.1";

    @Test
    public void rc61BuilderIsExactLabOnlyAndDebugOnly() throws Exception {
        String builder = read(
                "QCXR-XR-Wrapper/Assets/Editor/QuestCraftV71Rc61LabCliBuild.cs");

        assertTrue(builder.contains(
                "ApplicationIdentifier = \"com.qcxr.qcxr.canary262\""));
        assertTrue(builder.contains(
                "ProductName = \"QuestCraft Vivecraft Lab 26.2\""));
        assertTrue(builder.contains("VersionName = \"" + VERSION + "\""));
        assertTrue(builder.contains("VersionCode = \"71\""));
        assertTrue(builder.contains(
                "Builds/QuestCraft-Vivecraft-Lab-26.2-v71-rc.6.1-offline-local.apk"));
        assertTrue(builder.contains("HasArgument(\"-release\")"));
        assertTrue(builder.contains("QuestCraftCliBuild.BuildAndroid();"));
        assertFalse(builder.contains("com.qcxr.qcxr.dev262"));
    }

    @Test
    public void rc61IsExplicitlyAllowedByBothReleaseGates() throws Exception {
        String policy = read(
                "Pojlib/src/main/java/pojlib/LauncherResourceReleasePolicy.java");
        String launcher = read("QCXR-XR-Wrapper/Assets/Scripts/InstanceButton.cs");

        assertTrue(policy.contains("LAB_RC6_1_VERSION_NAME ="));
        assertTrue(policy.contains("LAB_RC6_1_VERSION_NAME.equals(versionName)"));
        assertTrue(policy.contains(VERSION));
        assertTrue(launcher.contains("LauncherResourceReleaseLabRc61Version ="));
        assertTrue(launcher.contains(
                "Application.version, LauncherResourceReleaseLabRc61Version"));
        assertTrue(launcher.contains(VERSION));
    }

    @Test
    public void verifierTreatsRc61AsRc6PayloadIdentity() throws Exception {
        String verifier = read("scripts/verify-dev-apk.ps1");

        assertTrue(verifier.contains(VERSION));
        assertTrue(verifier.contains("'questcraft-vivecraft-core-canary-v6'"));
        assertTrue(verifier.contains("'questcraft-veq-v71-canary-v4'"));
        assertTrue(verifier.contains("'0.7.0-v71.rc6'"));
        assertTrue(verifier.contains(
                "'bf7857e4212b18601d6e165a5453caf325bc3ab8eb1d093a324d6aa8c20f70fd'"));
    }

    private static String read(String relative) throws Exception {
        return new String(Files.readAllBytes(ROOT.resolve(relative)), StandardCharsets.UTF_8);
    }
}
