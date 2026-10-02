package pojlib;

import org.junit.Test;

import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;

import static org.junit.Assert.assertTrue;

public class VivecraftCoreCanarySourceIntegrationTest {
    private static final String LAB_PACKAGE = "com.qcxr.qcxr.canary262";
    private static final String STABLE_PACKAGE = "com.qcxr.qcxr.dev262";
    private static final String RC8_CORE_SHA256 =
            "addb01fa168033c42f97c615daf97cbb927b9e94400606eef27cfbe930015eab";

    @Test
    public void promotionIsLastPrelaunchMutationAndVerifierRollsBackOnFailure() throws Exception {
        String api = new String(Files.readAllBytes(Path.of("src/main/java/pojlib/API.java")),
                StandardCharsets.UTF_8);
        int config = api.indexOf("MinecraftInstances.CheckVivecraftConfig(instance);");
        int gate = api.indexOf("VivecraftCoreCanaryGate.prepare(activity, instance)", config);
        int success = api.indexOf("return true;", gate);
        assertTrue(config >= 0);
        assertTrue(gate > config);
        assertTrue(success > gate);

        String verifier = new String(Files.readAllBytes(
                Path.of("src/main/java/pojlib/UnattendedStackVerifier.java")),
                StandardCharsets.UTF_8);
        assertTrue(verifier.contains("VivecraftCoreCanaryGate.verifyVivecraftArtifact"));
        assertTrue(verifier.contains("if(coreCanaryPermitPresent && !verified)"));
        assertTrue(verifier.contains("VivecraftCoreCanaryGate.abortPromotedCandidate()"));
    }

    @Test
    public void coreCanaryRejectsNonLabPackageBeforeAnyInstanceOrFilesystemAccess()
            throws Exception {
        String gate = read("src/main/java/pojlib/VivecraftCoreCanaryGate.java");
        assertTrue(gate.contains("HARNESS_ID = \"questcraft-vivecraft-core-canary-v9\""));
        assertTrue(gate.contains("EXPECTED_BASELINE_FABRIC_VERSION ="));
        assertTrue(gate.contains("26.2-1.3.15+qc.v71.rc8-mining"));
        assertTrue(gate.contains(RC8_CORE_SHA256));
        int packageCheck = gate.indexOf(
                "if(!EXPECTED_PACKAGE.equals(activity.getPackageName()))");
        int instanceCheck = gate.indexOf("if(instance == null", packageCheck);
        int pathResolution = gate.indexOf("Paths.get(instance.gameDir)", packageCheck);
        int permitProbe = gate.indexOf(
                "if(hasProcessPermit() && !abortPromotedCandidate())", packageCheck);
        int markerProbe = gate.indexOf("Files.exists(marker", packageCheck);

        assertTrue(packageCheck >= 0);
        assertTrue(instanceCheck > packageCheck);
        assertTrue(pathResolution > instanceCheck);
        assertTrue(permitProbe > pathResolution);
        assertTrue(markerProbe > permitProbe);
    }

    @Test
    public void copyBatchModeUsesOneFixedJvmPropertyBeforeClasspath() throws Exception {
        String handler = read("src/main/java/pojlib/InstanceHandler.java");
        int generated = handler.indexOf("List<String> launchArgs = instance.generateLaunchArgs(account);");
        int classpath = handler.indexOf("int classpathIndex = launchArgs.indexOf(\"-cp\");", generated);
        int injected = handler.indexOf(
                "launchArgs.add(classpathIndex, OPENXR_COPY_BATCH_PROPERTY +", classpath);
        int launched = handler.indexOf("JREUtils.launchJavaVM(activity, launchArgs, instance);", injected);
        assertTrue(handler.contains(
                "OPENXR_COPY_BATCH_PROPERTY = \"-Dvivecraft.openxrCopyBatch=\""));
        assertTrue(generated >= 0);
        assertTrue(classpath > generated);
        assertTrue(injected > classpath);
        assertTrue(launched > injected);
        assertTrue(!handler.contains("JAVA_TOOL_OPTIONS"));

        String instances = read("src/main/java/pojlib/util/json/MinecraftInstances.java");
        assertTrue(instances.indexOf("allArgs.add(\"-cp\");") >= 0);

        String gate = read("src/main/java/pojlib/VivecraftCoreCanaryGate.java");
        assertTrue(gate.contains("static synchronized String takeOpenXrCopyBatchMode"));
        assertTrue(gate.contains("processCopyBatchModeClaimed = true;"));
        assertTrue(gate.contains("VivecraftCoreCanaryTransaction.permitMatches("));

        String transaction = read("src/main/java/pojlib/VivecraftCoreCanaryTransaction.java");
        assertTrue(transaction.contains("SCHEMA_VERSION = 2"));
        assertTrue(transaction.contains("\"openXrCopyBatchMode\""));
        assertTrue(transaction.contains("OPENXR_COPY_BATCH_OFF.equals(marker.openXrCopyBatchMode)"));
        assertTrue(transaction.contains("OPENXR_COPY_BATCH_ON.equals(marker.openXrCopyBatchMode)"));
    }

    @Test
    public void allRuntimeCanaryEntryPointsTargetOnlyTheIsolatedLabPackage() throws Exception {
        String coreGate = read("src/main/java/pojlib/VivecraftCoreCanaryGate.java");
        String autoplayGate = read("src/main/java/pojlib/UnattendedLocalTestGate.java");
        String api = read("src/main/java/pojlib/API.java");
        String activity = read("src/main/java/pojlib/UnityPlayerActivity.java");
        String launcher = read("../QCXR-XR-Wrapper/Assets/Scripts/InstanceButton.cs");
        String jniStorage = read("../QCXR-XR-Wrapper/Assets/Scripts/JNIStorage.cs");
        String labBuilder = read(
                "../QCXR-XR-Wrapper/Assets/Editor/QuestCraftV71Rc5LabCliBuild.cs");
        String personalBuilder = read(
                "../QCXR-XR-Wrapper/Assets/Editor/QuestCraftPersonalV71CliBuild.cs");
        String baseBuilder = read("../QCXR-XR-Wrapper/Assets/Editor/QuestCraftCliBuild.cs");
        String cameraParkPolicy = read(
                "src/main/java/pojlib/LauncherCameraParkPolicy.java");
        String resourceReleasePolicy = read(
                "src/main/java/pojlib/LauncherResourceReleasePolicy.java");
        String projectSettings = read("../QCXR-XR-Wrapper/ProjectSettings/ProjectSettings.asset");
        String resolverSettings = read(
                "../QCXR-XR-Wrapper/ProjectSettings/AndroidResolverDependencies.xml");
        String picoSettings = read(
                "../QCXR-XR-Wrapper/Assets/Resources/PicoSdkPCConfig.json");
        String deploy = read("../scripts/quest-vivecraft-core-canary.ps1");
        String autoplay = read("../scripts/run-vivecraft-local-autoplay.ps1");
        String labBuild = read("../scripts/build-v71-lab-rc5-integrated.ps1");
        String rc5Lock = read("../V71_LAB_RC5.lock.json");
        String pairedHarness = read("../scripts/quest-v70-lab-pair.ps1");
        String personalBuild = read("../scripts/build-v71-integrated.ps1");
        String apkVerifier = read("../scripts/verify-dev-apk.ps1");
        String abHarness = read("../scripts/quest-v69-core-ab.ps1");

        assertTrue(coreGate.contains("EXPECTED_PACKAGE = \"" + LAB_PACKAGE + "\""));
        assertTrue(!coreGate.contains("EXPECTED_PACKAGE = \"" + STABLE_PACKAGE + "\""));
        assertTrue(autoplayGate.contains("EXPECTED_PACKAGE = \"" + LAB_PACKAGE + "\""));
        assertTrue(!autoplayGate.contains(STABLE_PACKAGE));
        assertTrue(autoplayGate.contains(LAB_PACKAGE + ".action.UNATTENDED_ARM"));
        assertTrue(autoplayGate.contains(
                "EXTRA_LAUNCHER_CAMERA_PARK = \"launcher_camera_park\""));
        assertTrue(autoplayGate.contains(
                "EXTRA_LAUNCHER_RESOURCE_RELEASE = \"launcher_resource_release\""));
        assertTrue(autoplayGate.contains("normalizeCameraParkMode"));
        assertTrue(autoplayGate.contains("normalizeResourceReleaseMode"));
        assertTrue(autoplayGate.contains("LauncherCameraParkPolicy.State"));
        assertTrue(autoplayGate.contains("LauncherResourceReleasePolicy.State"));
        assertTrue(api.contains("isLauncherCameraParkEnabled"));
        assertTrue(api.contains("shouldReleaseLauncherResources"));
        assertTrue(api.contains("abortConsumedUnattendedLocalTestRequest"));
        assertTrue(api.contains("completeConsumedUnattendedLocalTestRequest"));
        assertTrue(api.contains("reportLauncherCameraParkResult"));
        assertTrue(autoplayGate.contains("resetForActivityLifecycle"));
        assertTrue(activity.contains("UnattendedLocalTestGate.resetForActivityLifecycle(this)"));
        int abortStart = autoplayGate.indexOf("public static void abortConsumed(Activity activity)");
        int completeStart = autoplayGate.indexOf(
                "public static void completeConsumed(Activity activity)", abortStart);
        int reportStart = autoplayGate.indexOf(
                "public static void reportLauncherCameraParkResult", abortStart);
        assertTrue(abortStart >= 0);
        assertTrue(completeStart > abortStart);
        assertTrue(reportStart > abortStart);
        assertTrue(!autoplayGate.substring(abortStart, completeStart)
                .contains("circuitOpen = false"));
        assertTrue(!autoplayGate.substring(completeStart, reportStart)
                .contains("circuitOpen = false"));
        assertTrue(launcher.contains("ParkLauncherCamerasIfRequested();"));
        assertTrue(launcher.contains("Camera.allCameras"));
        assertTrue(launcher.contains("abortConsumedUnattendedLocalTestRequest"));
        assertTrue(launcher.contains("completeConsumedUnattendedLocalTestRequest"));
        assertTrue(launcher.contains("reportLauncherCameraParkResult"));
        assertTrue(launcher.contains(
                "LauncherResourceReleaseLabPackage = \"" + LAB_PACKAGE + "\""));
        assertTrue(launcher.contains(
                "LauncherResourceReleaseLabRc6Version ="));
        assertTrue(launcher.contains(
                "LauncherResourceReleaseLabRc62Version ="));
        assertTrue(launcher.contains(
                "LauncherResourceReleaseLabRc7Version ="));
        assertTrue(launcher.contains(
                "LauncherResourceReleaseLabRc8Version ="));
        assertTrue(launcher.contains("ShouldReleaseLauncherResources();"));
        assertTrue(launcher.contains("ReleaseLauncherResourcesAfterHandoff();"));
        assertTrue(launcher.contains("Scene launcherScene = gameObject.scene;"));
        assertTrue(launcher.contains("root.SetActive(false);"));
        assertTrue(launcher.contains("RenderSettings.skybox = null;"));
        assertTrue(launcher.contains("target.Release();"));
        assertTrue(launcher.contains("Resources.UnloadUnusedAssets();"));
        assertTrue(!launcher.contains("mUnityPlayer.unload"));
        assertTrue(jniStorage.contains("Microphone.End(microphoneDevice);"));
        assertTrue(resourceReleasePolicy.contains(
                "LAB_PACKAGE = \"" + LAB_PACKAGE + "\""));
        assertTrue(resourceReleasePolicy.contains(
                "STABLE_PACKAGE = \"" + STABLE_PACKAGE + "\""));
        assertTrue(resourceReleasePolicy.contains(
                "LAB_RC6_VERSION_NAME ="));
        assertTrue(resourceReleasePolicy.contains(
                "LAB_RC6_2_VERSION_NAME ="));
        assertTrue(resourceReleasePolicy.contains(
                "LAB_RC7_VERSION_NAME ="));
        assertTrue(resourceReleasePolicy.contains(
                "LAB_RC8_VERSION_NAME ="));
        assertTrue(resourceReleasePolicy.contains("return MODE_OFF;"));
        assertTrue(resourceReleasePolicy.contains("&& hasActiveOverride()"));
        assertTrue(launcher.contains("OpenXRHandoffFadeTimeoutSeconds"));
        assertTrue(launcher.contains("The OpenXR handoff fade timed out."));
        assertTrue(labBuilder.contains("ApplicationIdentifier = \"" + LAB_PACKAGE + "\""));
        assertTrue(labBuilder.contains("ProductName = \"QuestCraft Vivecraft Lab 26.2\""));
        assertTrue(labBuilder.contains(
                "VersionName = \"6.0.1-26.2-vivecraft-personal.12-rc.5.2\""));
        assertTrue(labBuilder.contains("VersionCode = \"71\""));
        assertTrue(labBuilder.contains(
                "Builds/QuestCraft-Vivecraft-Lab-26.2-v71-rc.5.2-integrated-local.apk"));
        assertTrue(labBuilder.contains("HasArgument(\"-release\")"));
        assertTrue(personalBuilder.contains(
                "ApplicationIdentifier = \"" + STABLE_PACKAGE + "\""));
        assertTrue(personalBuilder.contains(
                "ProductName = \"Vivecraft Stable\""));
        assertTrue(personalBuilder.contains(
                "VersionName = \"6.0.1-26.2-vivecraft-personal.12\""));
        assertTrue(personalBuilder.contains("VersionCode = \"71\""));
        assertTrue(personalBuilder.contains(
                "Builds/QuestCraft-Vivecraft-26.2-personal.12-local.apk"));
        assertTrue(personalBuilder.contains("HasArgument(\"-release\")"));
        assertTrue(personalBuilder.contains(
                "QuestCraftCliBuild.BuildAcceptedPersonalV71Android();"));
        assertTrue(baseBuilder.contains("DefaultApplicationIdentifier = \"" + LAB_PACKAGE + "\""));
        assertTrue(baseBuilder.contains(
                "AcceptedPersonalApplicationIdentifier = \"" + STABLE_PACKAGE + "\""));
        assertTrue(baseBuilder.contains("BuildAndroidInternal(PersonalBuildIdentity.None)"));
        assertTrue(baseBuilder.contains("BuildAndroidInternal(PersonalBuildIdentity.V69)"));
        assertTrue(baseBuilder.contains("BuildAndroidInternal(PersonalBuildIdentity.V71)"));
        assertTrue(cameraParkPolicy.contains(
                "PERSONAL_PACKAGE = \"" + STABLE_PACKAGE + "\""));
        assertTrue(cameraParkPolicy.contains("isEligiblePackage"));
        assertTrue(autoplayGate.contains(
                "CAMERA_PARK_STATE.isEnabled(isCameraParkPackage(activity))"));
        assertTrue(autoplayGate.contains(
                "if(!isCameraParkPackage(activity))"));
        assertTrue(projectSettings.contains("Android: " + STABLE_PACKAGE));
        assertTrue(projectSettings.contains("productName: QuestCraft Vivecraft Personal 26.2"));
        assertTrue(projectSettings.contains(
                "bundleVersion: 6.0.1-26.2-vivecraft-personal.10"));
        assertTrue(projectSettings.contains("AndroidBundleVersionCode: 69"));
        assertTrue(resolverSettings.contains("bundleId\" value=\"" + STABLE_PACKAGE + "\""));
        assertTrue(picoSettings.contains("\"package_name\": \"" + STABLE_PACKAGE + "\""));
        assertTrue(picoSettings.contains(
                "\"package_version_name\": \"6.0.1-26.2-vivecraft-personal.10\""));
        assertTrue(deploy.contains("$script:Package = '" + LAB_PACKAGE + "'"));
        assertTrue(deploy.contains("$script:MarkerSchemaVersion = 2"));
        assertTrue(deploy.contains("[string] $OpenXrCopyBatchMode = 'OFF'"));
        assertTrue(deploy.contains("openXrCopyBatchMode"));
        assertTrue(autoplay.contains("$package = '" + LAB_PACKAGE + "'"));
        assertTrue(autoplay.contains("[string] $LauncherResourceRelease = 'ON'"));
        assertTrue(autoplay.contains("[switch] $AllowReleaseOffControl"));
        assertTrue(autoplay.contains(
                "'--es', 'launcher_resource_release', $LauncherResourceRelease"));
        assertTrue(labBuild.contains("git -C $repo status --porcelain --untracked-files=all"));
        assertTrue(labBuild.contains("clean testReleaseUnitTest assembleRelease"));
        assertTrue(labBuild.contains(
                "for ($buildNumber = 1; $buildNumber -le 2; $buildNumber++)"));
        assertTrue(labBuild.contains("PojlibAarSha256 = Get-Sha256 $builtAar"));
        assertTrue(labBuild.contains("AdbInvocations = 0"));
        assertTrue(labBuild.contains("QuestCraftV71Rc5LabCliBuild.BuildAndroid"));
        assertTrue(labBuild.contains("V71_LAB_RC5.lock.json"));
        assertTrue(rc5Lock.contains("\"expectedGameLogRelativePath\": " +
                "\"instances/26.2/logs/latest.log\""));
        assertTrue(rc5Lock.contains("\"expectedGameLogMinecraftVersion\": \"26.2\""));
        assertTrue(rc5Lock.contains("\"expectedGameLogCoreVersion\": " +
                "\"26.2-1.3.15+qc.v71.rc5\""));
        assertTrue(rc5Lock.contains("\"expectedGameLogVeqVersion\": " +
                "\"0.7.0-v70-canary.1\""));
        assertTrue(pairedHarness.contains("$script:LabPackage = '" + LAB_PACKAGE + "'"));
        assertTrue(pairedHarness.contains("Invoke-PairedRollback -BestEffort"));
        assertTrue(pairedHarness.contains("RollbackOrder = @('Core', 'VEQ')"));
        assertTrue(personalBuild.contains(
                "QuestCraftPersonalV71CliBuild.BuildAndroid"));
        assertTrue(personalBuild.contains("AllowStablePromotion"));
        assertTrue(personalBuild.contains("DeviceInvocations = 0"));
        assertTrue(apkVerifier.contains(LAB_PACKAGE + ".action.UNATTENDED_ARM"));
        assertTrue(apkVerifier.contains(STABLE_PACKAGE + ".action.UNATTENDED_ARM"));
        assertTrue(apkVerifier.contains("LauncherIdleThrottlePolicy"));
        assertTrue(apkVerifier.contains("QC_LAUNCHER_CAMERA_PARK_RESULT"));
        assertTrue(apkVerifier.contains("PersonalDexGate = $personalDexGate"));
        assertTrue(apkVerifier.contains("questcraft-vivecraft-core-canary-v5"));
        assertTrue(apkVerifier.contains("questcraft-veq-v71-canary-v3"));
        assertTrue(apkVerifier.contains("0.7.0-v70-canary.1"));
        assertTrue(apkVerifier.contains("questcraft-vivecraft-core-canary-v6"));
        assertTrue(apkVerifier.contains("questcraft-veq-v71-canary-v4"));
        assertTrue(apkVerifier.contains("0.7.0-v71.rc6"));
        assertTrue(apkVerifier.contains("questcraft-vivecraft-core-canary-v7"));
        assertTrue(apkVerifier.contains("26.2-1.3.15+qc.v71.rc6.2"));
        assertTrue(apkVerifier.contains("6449a62588fa944ba238f87178c43ee00bd10e3b223459606b4c002b7f2360af"));
        assertTrue(apkVerifier.contains("questcraft-vivecraft-core-canary-v8"));
        assertTrue(apkVerifier.contains("26.2-1.3.15+qc.v71.rc7"));
        assertTrue(apkVerifier.contains("a1a522c2bb949dbdc2a3ae475b900407324441da50d94e012a7c734b32e498d3"));
        assertTrue(apkVerifier.contains("questcraft-vivecraft-core-canary-v9"));
        assertTrue(apkVerifier.contains("26.2-1.3.15+qc.v71.rc8-mining"));
        assertTrue(apkVerifier.contains(RC8_CORE_SHA256));
        assertTrue(apkVerifier.contains("-Dvivecraft.openxrCopyBatch="));
        assertTrue(apkVerifier.contains("LabDexGate = $labDexGate"));
        assertTrue(abHarness.contains("Invoke-CoreDeploy $Candidate $mode"));
        assertTrue(abHarness.contains("OpenXrCopyBatchMode = $mode"));
        assertTrue(abHarness.contains("SameJarBothConditions = $true"));
        assertTrue(abHarness.contains("! grep -F -q $qOppositeMarker"));
        assertTrue(abHarness.contains(
                "$script:LabApkIdentity = Get-InstalledLabApkIdentity"));
        assertTrue(abHarness.contains("-ExpectedSignerSha256 $script:ExpectedLabSignerSha256"));
        assertTrue(abHarness.contains("LabApk = Copy-LabApkIdentity"));
    }

    private static String read(String path) throws Exception {
        return new String(Files.readAllBytes(Path.of(path)), StandardCharsets.UTF_8);
    }
}
