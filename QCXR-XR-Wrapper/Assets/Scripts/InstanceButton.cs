using System.Collections;
using System.Collections.Generic;
using System.IO;
using System.Threading;
using Newtonsoft.Json;
using UnityEngine;
using UnityEngine.SceneManagement;
using UnityEngine.XR;

public class InstanceButton : MonoBehaviour
{
    private const string UnattendedProfile = "26.2";
    private const string UnattendedVersion = "26.2";
    private const string UnattendedWorld = "FPS-Stress-Test";
    private const int UnattendedCountdownSeconds = 5;
    private const float OpenXRHandoffFadeTimeoutSeconds = 5f;
    private const float OpenXRHandoffReadyTimeoutSeconds = 240f;
    private const string LauncherResourceReleaseLabPackage = "com.qcxr.qcxr.canary262";
    private const string LauncherResourceReleaseLabRc4Version =
        "6.0.1-26.2-vivecraft-personal.12-rc.4";
    private const string LauncherResourceReleaseLabRc5Version =
        "6.0.1-26.2-vivecraft-personal.12-rc.5";
    private const string LauncherResourceReleaseLabRc51Version =
        "6.0.1-26.2-vivecraft-personal.12-rc.5.1";
    private const string LauncherResourceReleaseLabRc52Version =
        "6.0.1-26.2-vivecraft-personal.12-rc.5.2";
    private const string LauncherResourceReleaseLabRc6Version =
        "6.0.1-26.2-vivecraft-personal.12-rc.6";
    private const string LauncherResourceReleaseLabRc61Version =
        "6.0.1-26.2-vivecraft-personal.12-rc.6.1";
    private const string LauncherResourceReleaseLabRc62Version =
        "6.0.1-26.2-vivecraft-personal.12-rc.6.2";
    private const string LauncherResourceReleaseLabRc7Version =
        "6.0.1-26.2-vivecraft-personal.12-rc.7";
    private const string LauncherResourceReleaseLabRc8Version =
        "6.0.1-26.2-vivecraft-personal.12-rc.8";
    private const string LauncherResourceReleaseStablePackage = "com.qcxr.qcxr.dev262";
    private const string LauncherResourceReleaseStableVersion =
        "6.0.1-26.2-vivecraft-personal.12";
    private const string LauncherResourceReleaseStableV72Version =
        "6.0.1-26.2-vivecraft-personal.13";
    private static bool launcherResourcesReleased;
    public static string currInstName;
    private bool hasDefaulted;
    public ConfigHandler configHandler;
    public UIHandler uiHandler;
    public CanvasGroup ScreenFade;
    private volatile bool launchPrepared;
    private volatile bool prelaunchFailed;
    private volatile bool launchDispatchFailed;
    private bool launchInProgress;
    private bool waitingForOpenXRHandoff;
    private bool openXRHandoffInProgress;
    private float openXRHandoffReadyDeadline;
    private PojlibInstance preparedInstance;
    private volatile bool preparedUnattendedQuickPlay;
    private volatile bool launchStateUnsafe;
    private bool unattendedRequestScheduled;
    private bool unattendedWaitReported;
    private float nextUnattendedPoll;
    private Coroutine unattendedCountdown;

    public void Update()
    {
        if (Application.platform != RuntimePlatform.Android)
            return;
        TryScheduleUnattendedLaunch();
        currInstName = JNIStorage.instance.instancesDropdown.options[JNIStorage.instance.instancesDropdown.value].text;

        if (prelaunchFailed)
        {
            prelaunchFailed = false;
            bool cleanupSucceeded = AbortConsumedUnattendedRun();
            launchInProgress = !cleanupSucceeded;
            uiHandler.SetAndShowError(cleanupSucceeded
                ? "Prelaunch checks failed!"
                : "Prelaunch cleanup failed. Restart the Lab app before trying again.");
        }

        if (launchDispatchFailed)
        {
            launchDispatchFailed = false;
            bool cleanupSucceeded = AbortConsumedUnattendedRun();
            waitingForOpenXRHandoff = false;
            openXRHandoffInProgress = false;
            openXRHandoffReadyDeadline = 0f;
            launchInProgress = !cleanupSucceeded;
            if (cleanupSucceeded)
            {
                ProgressBarManager.started = false;
                uiHandler.KillSetter();
            }
            Debug.LogError("QC_JVM_LAUNCH_DISPATCH_REJECTED");
            uiHandler.SetAndShowError(cleanupSucceeded
                ? "Minecraft launch dispatch failed!"
                : "Launch cleanup failed. Restart the Lab app before trying again.");
        }

        if (launchPrepared)
        {
            launchPrepared = false;
            BeginJavaLaunch(preparedInstance);
        }

        if (waitingForOpenXRHandoff && !openXRHandoffInProgress)
        {
            bool gameReady;
            try
            {
                gameReady = JNIStorage.apiClass.GetStatic<bool>("gameReady");
            }
            catch (System.Exception exception)
            {
                RestartAfterOpenXRHandoffWaitFailure(
                    "QC_OPENXR_HANDOFF_READY_POLL_FAILED type=" + exception.GetType().Name);
                return;
            }

            if (gameReady)
            {
                openXRHandoffInProgress = true;
                StartCoroutine(CompleteOpenXRHandoff());
            }
            else if (Time.realtimeSinceStartup >= openXRHandoffReadyDeadline)
            {
                RestartAfterOpenXRHandoffWaitFailure(
                    "QC_OPENXR_HANDOFF_READY_TIMEOUT seconds=" + OpenXRHandoffReadyTimeoutSeconds);
            }
        }
    }

    public void SelectInstance()
    {
        if (Application.platform != RuntimePlatform.Android) return;
        currInstName = JNIStorage.instance.instancesDropdown.options[JNIStorage.instance.instancesDropdown.value].text;
        configHandler.SetLastSelectedInstance(JNIStorage.instance.instancesDropdown.value);
    }

    private static void CreateDefaultInstance(string name)
    {
        JNIStorage.apiClass.CallStatic<AndroidJavaObject>("createNewInstance", JNIStorage.activity, JNIStorage.instancesObj, name, true, name, "Fabric", null);
        JNIStorage.instance.uiHandler.SetAndShowError(currInstName + " is now installing.");
        JNIStorage.instance.UpdateInstances();
    }

    public void LaunchCurrentInstance()
    {
        if (launchStateUnsafe)
        {
            uiHandler.SetAndShowError("Restart the Lab app before launching again.");
            return;
        }

        if (unattendedCountdown != null)
        {
            StopCoroutine(unattendedCountdown);
            unattendedCountdown = null;
            unattendedRequestScheduled = false;
            JNIStorage.apiClass.CallStatic("cancelUnattendedLocalTestRequest", JNIStorage.activity);
        }

        if (launchInProgress)
            return;

        if (JNIStorage.accountObj == null)
        {
            uiHandler.SetAndShowError("Sign in to Microsoft before launching Minecraft.");
            return;
        }

        if (JNIStorage.GetInstance(currInstName) == null)
        {
            Debug.Log("Instance is null!");
            
            CreateDefaultInstance(currInstName);
            return;
        }
        
        
        PojlibInstance instance = JNIStorage.GetInstance(currInstName);
        launchInProgress = true;
        uiHandler.PlaySetter();
        ProgressBarManager.started = true;
        new Thread(() =>
        {
            AndroidJNI.AttachCurrentThread();
            try
            {
                if (!JNIStorage.apiClass.CallStatic<bool>("prelaunch", JNIStorage.activity,
                        JNIStorage.instancesObj, instance.raw))
                {
                    prelaunchFailed = true;
                    return;
                }

                preparedInstance = instance;
                launchPrepared = true;
            }
            catch
            {
                prelaunchFailed = true;
            }
            finally
            {
                AndroidJNI.DetachCurrentThread();
            }
        }).Start();
    }

    private void BeginJavaLaunch(PojlibInstance instance)
    {
        waitingForOpenXRHandoff = true;
        openXRHandoffReadyDeadline =
            Time.realtimeSinceStartup + OpenXRHandoffReadyTimeoutSeconds;
        new Thread(() =>
        {
            AndroidJNI.AttachCurrentThread();
            try
            {
                bool unattendedLaunch = preparedUnattendedQuickPlay;
                bool launchAccepted;
                if (unattendedLaunch)
                {
                    launchAccepted = JNIStorage.apiClass.CallStatic<bool>(
                        "launchUnattendedLocalTest", JNIStorage.activity,
                        JNIStorage.accountObj, instance.raw);
                }
                else
                {
                    launchAccepted = JNIStorage.apiClass.CallStatic<bool>(
                        "launchInstance", JNIStorage.activity, JNIStorage.accountObj, instance.raw);
                }

                if (!launchAccepted)
                {
                    launchDispatchFailed = true;
                    return;
                }

                if (unattendedLaunch)
                {
                    try
                    {
                        JNIStorage.apiClass.CallStatic("reportUnattendedLocalTestMilestone",
                            JNIStorage.activity, "QC_AUTOPLAY_LAUNCH_DISPATCHED");
                    }
                    catch (System.Exception exception)
                    {
                        // Dispatch has already succeeded. A diagnostic milestone
                        // failure must not disarm the OpenXR handoff watchdog.
                        Debug.LogWarning("QC_AUTOPLAY_LAUNCH_MILESTONE_FAILED type=" +
                            exception.GetType().Name);
                    }
                }
            }
            catch (System.Exception)
            {
                launchDispatchFailed = true;
            }
            finally
            {
                AndroidJNI.DetachCurrentThread();
            }
        }).Start();
    }

    private void RestartAfterOpenXRHandoffWaitFailure(string diagnostic)
    {
        waitingForOpenXRHandoff = false;
        openXRHandoffInProgress = false;
        openXRHandoffReadyDeadline = 0f;
        launchStateUnsafe = true;
        AbortConsumedUnattendedRun();
        Debug.LogError(diagnostic + "; restarting launcher process.");

        try
        {
            JNIStorage.apiClass.CallStatic("restartLauncher", JNIStorage.activity);
        }
        catch (System.Exception exception)
        {
            Debug.LogError("QC_LAUNCHER_RESTART_REQUEST_FAILED type=" + exception.GetType().Name);
            uiHandler.SetAndShowError(
                "Minecraft launch stalled. Restart the app before trying again.");
        }
    }

    private void TryScheduleUnattendedLaunch()
    {
        if (launchStateUnsafe || unattendedRequestScheduled || launchInProgress ||
            Time.unscaledTime < nextUnattendedPoll)
            return;

        nextUnattendedPoll = Time.unscaledTime + 0.5f;
        if (JNIStorage.apiClass == null || JNIStorage.activity == null || JNIStorage.instancesObj == null ||
            JNIStorage.accountObj == null)
            return;
        if (!JNIStorage.apiClass.CallStatic<bool>("isUnattendedLocalTestPending", JNIStorage.activity))
            return;

        PojlibInstance instance = JNIStorage.GetInstance(UnattendedProfile);
        if (instance == null || !string.Equals(instance.versionName, UnattendedVersion,
                System.StringComparison.Ordinal))
        {
            ReportUnattendedWaitOnce("QC_AUTOPLAY_WAITING_PROFILE");
            return;
        }

        string levelDat = Path.Combine(instance.gameDir, "saves", UnattendedWorld, "level.dat");
        if (!File.Exists(levelDat))
        {
            ReportUnattendedWaitOnce("QC_AUTOPLAY_WAITING_WORLD");
            return;
        }

        unattendedRequestScheduled = true;
        unattendedCountdown = StartCoroutine(BeginUnattendedCountdown(instance));
    }

    private void ReportUnattendedWaitOnce(string milestone)
    {
        if (unattendedWaitReported)
            return;
        unattendedWaitReported = true;
        JNIStorage.apiClass.CallStatic("reportUnattendedLocalTestMilestone", JNIStorage.activity, milestone);
    }

    private IEnumerator BeginUnattendedCountdown(PojlibInstance instance)
    {
        JNIStorage.apiClass.CallStatic("reportUnattendedLocalTestMilestone", JNIStorage.activity,
            "QC_AUTOPLAY_COUNTDOWN_5");
        for (int remaining = UnattendedCountdownSeconds; remaining > 0; remaining--)
        {
            if (!JNIStorage.apiClass.CallStatic<bool>("isUnattendedLocalTestPending", JNIStorage.activity))
            {
                JNIStorage.apiClass.CallStatic("reportUnattendedLocalTestMilestone", JNIStorage.activity,
                    "QC_AUTOPLAY_COUNTDOWN_CANCELLED");
                unattendedRequestScheduled = false;
                unattendedCountdown = null;
                yield break;
            }
            uiHandler.SetAndShowError(
                $"Authenticated local benchmark starts in {remaining} second(s).\nPress Play to cancel and launch normally.");
            yield return new WaitForSecondsRealtime(1f);
        }

        unattendedCountdown = null;
        if (!JNIStorage.apiClass.CallStatic<bool>("consumeUnattendedLocalTestRequest", JNIStorage.activity))
        {
            unattendedRequestScheduled = false;
            yield break;
        }

        uiHandler.errorMenu.SetActive(false);
        preparedUnattendedQuickPlay = true;
        JNIStorage.apiClass.CallStatic("reportUnattendedLocalTestMilestone", JNIStorage.activity,
            "QC_AUTOPLAY_READY");
        launchInProgress = true;
        uiHandler.PlaySetter();
        ProgressBarManager.started = true;
        new Thread(() =>
        {
            AndroidJNI.AttachCurrentThread();
            try
            {
                if (!JNIStorage.apiClass.CallStatic<bool>("prelaunch", JNIStorage.activity,
                        JNIStorage.instancesObj, instance.raw))
                {
                    JNIStorage.apiClass.CallStatic("reportUnattendedLocalTestMilestone", JNIStorage.activity,
                        "QC_AUTOPLAY_PRELAUNCH_FAILED");
                    prelaunchFailed = true;
                    return;
                }

                if (!JNIStorage.apiClass.CallStatic<bool>("verifyUnattendedStackArtifacts",
                        JNIStorage.activity, instance.raw))
                {
                    JNIStorage.apiClass.CallStatic("reportUnattendedLocalTestMilestone", JNIStorage.activity,
                        "QC_AUTOPLAY_STACK_HASH_FAILED");
                    prelaunchFailed = true;
                    return;
                }

                JNIStorage.apiClass.CallStatic("reportUnattendedLocalTestMilestone", JNIStorage.activity,
                    "QC_AUTOPLAY_PRELAUNCH_OK");
                preparedInstance = instance;
                launchPrepared = true;
            }
            catch
            {
                prelaunchFailed = true;
            }
            finally
            {
                AndroidJNI.DetachCurrentThread();
            }
        }).Start();
    }

    private IEnumerator CompleteOpenXRHandoff()
    {
        bool fadeComplete = false;
        bool releaseLauncherResources = false;
        System.Exception handoffFailure = null;
        try
        {
            if (ScreenFade == null || ScreenFade.gameObject == null)
                throw new System.InvalidOperationException("The handoff fade canvas is unavailable.");
            LeanTween.value(ScreenFade.gameObject, 0, 1, 1)
                .setOnUpdate(alpha => ScreenFade.alpha = alpha)
                .setOnComplete(() => fadeComplete = true);
        }
        catch (System.Exception exception)
        {
            handoffFailure = exception;
        }

        float fadeDeadline = Time.realtimeSinceStartup + OpenXRHandoffFadeTimeoutSeconds;
        while (handoffFailure == null && !fadeComplete && Time.realtimeSinceStartup < fadeDeadline)
            yield return null;
        if (handoffFailure == null && !fadeComplete)
            handoffFailure = new System.TimeoutException("The OpenXR handoff fade timed out.");

        if (handoffFailure == null)
        {
            try
            {
                JNIStorage.CloseXR();
            }
            catch (System.Exception exception)
            {
                handoffFailure = exception;
            }
        }

        // Give Unity's render loop two synchronization points to release the runtime session.
        if (handoffFailure == null)
        {
            yield return new WaitForEndOfFrame();
            yield return null;
        }

        if (handoffFailure == null)
        {
            try
            {
                JNIStorage.apiClass.CallStatic("releaseOpenXRHandoff");
                releaseLauncherResources = ShouldReleaseLauncherResources();
                ParkLauncherCamerasIfRequested();
                if (!CompleteConsumedUnattendedRun())
                {
                    launchStateUnsafe = true;
                    releaseLauncherResources = false;
                }
            }
            catch (System.Exception exception)
            {
                handoffFailure = exception;
            }
        }

        if (handoffFailure != null)
        {
            AbortConsumedUnattendedRun();
            launchStateUnsafe = true;
            Debug.LogError("OpenXR handoff failed; another launch is blocked until restart: " +
                handoffFailure.Message);
            uiHandler.SetAndShowError("OpenXR handoff failed. Restart the Lab app before trying again.");
        }

        waitingForOpenXRHandoff = false;
        openXRHandoffInProgress = false;
        openXRHandoffReadyDeadline = 0f;

        // This is intentionally last: deactivating the launcher scene also
        // deactivates the MonoBehaviour that owns this coroutine.
        if (handoffFailure == null && releaseLauncherResources)
            ReleaseLauncherResourcesAfterHandoff();
    }

    private bool AbortConsumedUnattendedRun()
    {
        if (!preparedUnattendedQuickPlay || JNIStorage.apiClass == null || JNIStorage.activity == null)
            return true;

        try
        {
            JNIStorage.apiClass.CallStatic(
                "abortConsumedUnattendedLocalTestRequest", JNIStorage.activity);
            preparedUnattendedQuickPlay = false;
            return true;
        }
        catch (System.Exception exception)
        {
            preparedUnattendedQuickPlay = false;
            launchStateUnsafe = true;
            Debug.LogWarning("Could not clear consumed autoplay state: " + exception.Message);
            return false;
        }
    }

    private bool CompleteConsumedUnattendedRun()
    {
        if (!preparedUnattendedQuickPlay || JNIStorage.apiClass == null || JNIStorage.activity == null)
            return true;

        try
        {
            JNIStorage.apiClass.CallStatic(
                "completeConsumedUnattendedLocalTestRequest", JNIStorage.activity);
            preparedUnattendedQuickPlay = false;
            return true;
        }
        catch (System.Exception exception)
        {
            preparedUnattendedQuickPlay = false;
            launchStateUnsafe = true;
            Debug.LogWarning("Could not complete consumed autoplay state: " + exception.Message);
            return false;
        }
    }

    private static void ParkLauncherCamerasIfRequested()
    {
        string[] expectedCameraNames = { "DesktopCamera", "Main Camera", "Quester renderer" };
        try
        {
            if (!JNIStorage.apiClass.CallStatic<bool>(
                    "isLauncherCameraParkEnabled", JNIStorage.activity))
                return;

            Dictionary<string, Camera> launcherCameras = new Dictionary<string, Camera>();
            foreach (Camera camera in Camera.allCameras)
            {
                if (camera == null || !camera.enabled)
                    continue;

                string cameraName = camera.gameObject.name;
                foreach (string expectedName in expectedCameraNames)
                {
                    if (!string.Equals(cameraName, expectedName, System.StringComparison.Ordinal))
                        continue;
                    if (launcherCameras.ContainsKey(expectedName))
                        throw new System.InvalidOperationException(
                            "Duplicate launcher camera: " + expectedName);
                    launcherCameras.Add(expectedName, camera);
                    break;
                }
            }

            if (launcherCameras.Count == 0)
            {
                JNIStorage.apiClass.CallStatic(
                    "reportLauncherCameraParkResult", JNIStorage.activity, "NO_CAMERAS", 0);
                return;
            }
            if (launcherCameras.Count != expectedCameraNames.Length)
                throw new System.InvalidOperationException(
                    $"Expected {expectedCameraNames.Length} launcher cameras, found {launcherCameras.Count}.");

            List<Camera> changedCameras = new List<Camera>(expectedCameraNames.Length);
            try
            {
                foreach (string expectedName in expectedCameraNames)
                {
                    Camera camera = launcherCameras[expectedName];
                    changedCameras.Add(camera);
                    camera.enabled = false;
                }
            }
            catch (System.Exception disableException)
            {
                List<System.Exception> rollbackFailures = new List<System.Exception>();
                foreach (Camera camera in changedCameras)
                {
                    try
                    {
                        if (camera != null)
                            camera.enabled = true;
                    }
                    catch (System.Exception rollbackException)
                    {
                        rollbackFailures.Add(rollbackException);
                    }
                }
                if (rollbackFailures.Count > 0)
                {
                    rollbackFailures.Insert(0, disableException);
                    throw new System.AggregateException(
                        "Launcher camera parking and rollback both failed.", rollbackFailures);
                }
                throw;
            }

            try
            {
                JNIStorage.apiClass.CallStatic(
                    "reportLauncherCameraParkResult", JNIStorage.activity,
                    "APPLIED", changedCameras.Count);
            }
            catch (System.Exception exception)
            {
                // Reporting is diagnostic only. Once all launcher-owned cameras
                // are parked successfully, a logging failure must not restore
                // their render cost.
                Debug.LogWarning("Launcher camera park reporting failed: " + exception.Message);
            }
        }
        catch (System.Exception exception)
        {
            try
            {
                JNIStorage.apiClass.CallStatic(
                    "reportLauncherCameraParkResult", JNIStorage.activity, "FAILED", 0);
            }
            catch (System.Exception)
            {
                // Keep the original failure as the useful diagnostic.
            }
            Debug.LogWarning("Launcher camera park failed safely: " + exception.Message);
        }
    }

    private static bool ShouldReleaseLauncherResources()
    {
        if (Application.platform != RuntimePlatform.Android || JNIStorage.apiClass == null ||
            JNIStorage.activity == null)
            return false;

        bool exactLab = string.Equals(Application.identifier,
                LauncherResourceReleaseLabPackage, System.StringComparison.Ordinal) &&
            (string.Equals(Application.version, LauncherResourceReleaseLabRc4Version,
                System.StringComparison.Ordinal) ||
             string.Equals(Application.version, LauncherResourceReleaseLabRc5Version,
                System.StringComparison.Ordinal) ||
             string.Equals(Application.version, LauncherResourceReleaseLabRc51Version,
                System.StringComparison.Ordinal) ||
             string.Equals(Application.version, LauncherResourceReleaseLabRc52Version,
                System.StringComparison.Ordinal) ||
             string.Equals(Application.version, LauncherResourceReleaseLabRc6Version,
                System.StringComparison.Ordinal) ||
             string.Equals(Application.version, LauncherResourceReleaseLabRc61Version,
                System.StringComparison.Ordinal) ||
             string.Equals(Application.version, LauncherResourceReleaseLabRc62Version,
                System.StringComparison.Ordinal) ||
             string.Equals(Application.version, LauncherResourceReleaseLabRc7Version,
                System.StringComparison.Ordinal) ||
             string.Equals(Application.version, LauncherResourceReleaseLabRc8Version,
                System.StringComparison.Ordinal));
        bool exactStable = string.Equals(Application.identifier,
                LauncherResourceReleaseStablePackage, System.StringComparison.Ordinal) &&
            (string.Equals(Application.version, LauncherResourceReleaseStableVersion,
                System.StringComparison.Ordinal) ||
             string.Equals(Application.version, LauncherResourceReleaseStableV72Version,
                System.StringComparison.Ordinal));
        if (!exactLab && !exactStable)
            return false;

        try
        {
            return JNIStorage.apiClass.CallStatic<bool>(
                "shouldReleaseLauncherResources", JNIStorage.activity);
        }
        catch (System.Exception exception)
        {
            Debug.LogWarning("Launcher resource-release gate failed closed: " + exception.Message);
            return false;
        }
    }

    private void ReleaseLauncherResourcesAfterHandoff()
    {
        if (launcherResourcesReleased ||
            Application.platform != RuntimePlatform.Android ||
            !ShouldReleaseLauncherResources())
            return;

        // Bind cleanup to the scene that owns this launcher button. The active
        // scene can change during handoff and must never become a cleanup target.
        Scene launcherScene = gameObject.scene;
        if (!launcherScene.IsValid() || !launcherScene.isLoaded)
        {
            Debug.LogWarning("Launcher resource release skipped: active scene is unavailable.");
            return;
        }

        GameObject[] launcherRoots = launcherScene.GetRootGameObjects();
        if (launcherRoots == null || launcherRoots.Length == 0)
        {
            Debug.LogWarning("Launcher resource release skipped: active scene has no roots.");
            return;
        }

        int discoveredCameras = 0;
        int disabledCameras = 0;
        int releasedRenderTargets = 0;
        bool microphoneReleased = false;
        bool degraded = false;
        HashSet<RenderTexture> renderTargets = new HashSet<RenderTexture>();

        try
        {
            microphoneReleased = JNIStorage.StopLauncherMicrophone();
        }
        catch (System.Exception exception)
        {
            degraded = true;
            // Microphone cleanup must not prevent the remaining launcher
            // resources from being released after a successful handoff.
            Debug.LogWarning("Launcher microphone release failed safely: " + exception.Message);
        }

        foreach (GameObject root in launcherRoots)
        {
            if (root == null)
                continue;
            Camera[] cameras;
            try
            {
                cameras = root.GetComponentsInChildren<Camera>(true);
            }
            catch (System.Exception exception)
            {
                degraded = true;
                Debug.LogWarning("Launcher camera discovery failed safely: " + exception.Message);
                continue;
            }

            foreach (Camera camera in cameras)
            {
                if (camera == null)
                    continue;
                discoveredCameras++;
                try
                {
                    if (camera.enabled)
                    {
                        camera.enabled = false;
                        disabledCameras++;
                    }

                    RenderTexture target = camera.targetTexture;
                    camera.targetTexture = null;
                    if (target != null)
                        renderTargets.Add(target);
                }
                catch (System.Exception exception)
                {
                    degraded = true;
                    Debug.LogWarning("Launcher camera release failed safely: " + exception.Message);
                }
            }
        }

        foreach (RenderTexture target in renderTargets)
        {
            try
            {
                if (target != null && target.IsCreated())
                {
                    target.Release();
                    releasedRenderTargets++;
                }
            }
            catch (System.Exception exception)
            {
                degraded = true;
                Debug.LogWarning("Launcher render-target release failed safely: " + exception.Message);
            }
        }

        try
        {
            RenderSettings.skybox = null;
        }
        catch (System.Exception exception)
        {
            degraded = true;
            Debug.LogWarning("Launcher skybox release failed safely: " + exception.Message);
        }

        // A clean embedded-JVM exit recreates the entire Android process. Do
        // not reactivate launcher roots in-process while Minecraft owns OpenXR.
        foreach (GameObject root in launcherRoots)
        {
            if (root == null)
                continue;
            try
            {
                root.SetActive(false);
            }
            catch (System.Exception exception)
            {
                degraded = true;
                Debug.LogWarning("Launcher root release failed safely: " + exception.Message);
            }
        }

        try
        {
            Resources.UnloadUnusedAssets();
        }
        catch (System.Exception exception)
        {
            degraded = true;
            Debug.LogWarning("Launcher unused-assets request failed safely: " + exception.Message);
        }

        // A fully successful release is terminal for this process. A degraded
        // release remains retryable if the owning launcher object survived.
        launcherResourcesReleased = !degraded;
        Debug.Log("QC_LAUNCHER_RESOURCE_RELEASE_" + (degraded ? "DEGRADED" : "APPLIED") +
            " roots=" + launcherRoots.Length +
            " cameras=" + discoveredCameras +
            " newlyDisabledCameras=" + disabledCameras +
            " renderTargets=" + releasedRenderTargets +
            " microphone=" + microphoneReleased);
    }

    public void KillInstance()
    {
        JNIStorage.apiClass.CallStatic("restartLauncher", JNIStorage.activity);
    }

    public async void MirrorNativesForInstance()
    {
        PojlibInstance instance = JNIStorage.GetInstance(currInstName);
        JNIStorage.apiClass.CallStatic(
            "mirrorNativesInFolder",
            JNIStorage.activity,
            JNIStorage.instancesObj,
            instance.raw,
            Path.Combine(Application.persistentDataPath, "natives"));
    }

    public async void ImportSaves()
    {
        PojlibInstance instance = JNIStorage.GetInstance(currInstName);
        JNIStorage.apiClass.CallStatic(
            "unzipSavesFromFolder",
            instance.raw,
            Path.Combine(Application.persistentDataPath, "import-saves"));
    }
}
