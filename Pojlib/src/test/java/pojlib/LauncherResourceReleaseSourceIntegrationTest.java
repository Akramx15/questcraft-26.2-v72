package pojlib;

import org.junit.Test;

import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;

import static org.junit.Assert.assertTrue;

public class LauncherResourceReleaseSourceIntegrationTest {
    private static final String LAB_PACKAGE = "com.qcxr.qcxr.canary262";
    private static final String STABLE_PACKAGE = "com.qcxr.qcxr.dev262";

    @Test
    public void releaseIsPinnedToExactV71AndV72IdentitiesAndRunsAfterHandoff() throws Exception {
        String gate = read("src/main/java/pojlib/UnattendedLocalTestGate.java");
        String policy = read("src/main/java/pojlib/LauncherResourceReleasePolicy.java");
        String api = read("src/main/java/pojlib/API.java");
        String launcher = read("../QCXR-XR-Wrapper/Assets/Scripts/InstanceButton.cs");
        String jni = read("../QCXR-XR-Wrapper/Assets/Scripts/JNIStorage.cs");
        String helper = read("../scripts/run-vivecraft-local-autoplay.ps1");

        assertTrue(policy.contains("LAB_PACKAGE = \"" + LAB_PACKAGE + "\""));
        assertTrue(policy.contains("STABLE_PACKAGE = \"" + STABLE_PACKAGE + "\""));
        assertTrue(policy.contains("LAB_VERSION_CODE = 71L"));
        assertTrue(policy.contains("STABLE_VERSION_CODE = 71L"));
        assertTrue(policy.contains("STABLE_V72_VERSION_CODE = 72L"));
        assertTrue(policy.contains("STABLE_V72_VERSION_NAME ="));
        assertTrue(policy.contains("\"6.0.1-26.2-vivecraft-personal.13\""));
        assertTrue(policy.contains("return MODE_OFF;"));
        assertTrue(policy.contains("identity == BuildIdentity.LAB_V71_RC4 ||"));
        assertTrue(policy.contains("identity == BuildIdentity.LAB_V71_RC5"));
        assertTrue(gate.contains(
                "EXTRA_LAUNCHER_RESOURCE_RELEASE = \"launcher_resource_release\""));
        assertTrue(gate.contains(
                "RESOURCE_RELEASE_STATE.shouldRelease("));
        assertTrue(api.contains("shouldReleaseLauncherResources"));

        int handoff = launcher.indexOf("JNIStorage.apiClass.CallStatic(\"releaseOpenXRHandoff\")");
        int snapshot = launcher.indexOf("ShouldReleaseLauncherResources();", handoff);
        int complete = launcher.indexOf("CompleteConsumedUnattendedRun()", snapshot);
        int clearWaiting = launcher.indexOf("waitingForOpenXRHandoff = false;", complete);
        int release = launcher.indexOf("ReleaseLauncherResourcesAfterHandoff();", clearWaiting);
        assertTrue(handoff >= 0);
        assertTrue(snapshot > handoff);
        assertTrue(complete > snapshot);
        assertTrue(clearWaiting > complete);
        assertTrue(release > clearWaiting);

        int releaseMethod = launcher.indexOf("private void ReleaseLauncherResourcesAfterHandoff()");
        int stableGate = launcher.indexOf("!ShouldReleaseLauncherResources()", releaseMethod);
        int sceneMutation = launcher.indexOf("Scene launcherScene = gameObject.scene;", releaseMethod);
        assertTrue(releaseMethod > release);
        assertTrue(stableGate > releaseMethod && stableGate < sceneMutation);
        assertTrue(launcher.contains("LauncherResourceReleaseLabPackage = \"" + LAB_PACKAGE + "\""));
        assertTrue(launcher.contains("LauncherResourceReleaseStablePackage = \"" + STABLE_PACKAGE + "\""));
        assertTrue(launcher.contains("6.0.1-26.2-vivecraft-personal.12-rc.4"));
        assertTrue(launcher.contains("6.0.1-26.2-vivecraft-personal.12-rc.5"));
        assertTrue(launcher.contains("6.0.1-26.2-vivecraft-personal.12-rc.5.1"));
        assertTrue(launcher.contains("6.0.1-26.2-vivecraft-personal.12-rc.5.2"));
        assertTrue(launcher.contains("6.0.1-26.2-vivecraft-personal.12-rc.6"));
        assertTrue(launcher.contains("6.0.1-26.2-vivecraft-personal.12-rc.6.1"));
        assertTrue(launcher.contains("6.0.1-26.2-vivecraft-personal.12-rc.6.2"));
        assertTrue(launcher.contains("6.0.1-26.2-vivecraft-personal.12-rc.7"));
        assertTrue(launcher.contains("6.0.1-26.2-vivecraft-personal.12-rc.8"));
        assertTrue(launcher.contains("6.0.1-26.2-vivecraft-personal.12"));
        assertTrue(launcher.contains("LauncherResourceReleaseStableV72Version ="));
        assertTrue(launcher.contains("6.0.1-26.2-vivecraft-personal.13"));
        assertTrue(launcher.contains("root.SetActive(false);"));
        assertTrue(launcher.contains("camera.targetTexture = null;"));
        assertTrue(launcher.contains("target.Release();"));
        assertTrue(launcher.contains("RenderSettings.skybox = null;"));
        assertTrue(launcher.contains("Resources.UnloadUnusedAssets();"));
        assertTrue(!launcher.contains("mUnityPlayer.unload"));
        assertTrue(jni.contains("Microphone.End(microphoneDevice);"));
        assertTrue(jni.contains("UnityEngine.Object.Destroy(microphoneClip);"));
        assertTrue(jni.contains("throw new InvalidOperationException("));
        assertTrue(launcher.contains("Launcher camera discovery failed safely:"));
        assertTrue(launcher.contains("launcherResourcesReleased = !degraded;"));

        assertTrue(helper.contains("[string] $LauncherResourceRelease = 'ON'"));
        assertTrue(helper.contains("[switch] $AllowReleaseOffControl"));
        assertTrue(helper.contains(
                "'--es', 'launcher_resource_release', $LauncherResourceRelease"));
    }

    private static String read(String path) throws Exception {
        return new String(Files.readAllBytes(Path.of(path)), StandardCharsets.UTF_8);
    }
}
