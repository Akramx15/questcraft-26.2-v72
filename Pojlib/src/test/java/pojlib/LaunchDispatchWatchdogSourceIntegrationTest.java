package pojlib;

import org.junit.Test;

import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;

import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertTrue;

public class LaunchDispatchWatchdogSourceIntegrationTest {
    @Test
    public void launchAcceptancePropagatesFromInstanceHandlerThroughUnity() throws Exception {
        String handler = read("src/main/java/pojlib/InstanceHandler.java");
        String api = read("src/main/java/pojlib/API.java");
        String launcher = read("../QCXR-XR-Wrapper/Assets/Scripts/InstanceButton.cs");

        assertTrue(handler.contains(
                "public static boolean launchInstance(Activity activity, MinecraftAccount account,"));
        assertTrue(handler.contains("return launchInstance(activity, account, instance, false);"));
        int jvmDispatch = handler.indexOf(
                "JREUtils.launchJavaVM(activity, launchArgs, instance);");
        int accepted = handler.indexOf("return true;", jvmDispatch);
        int rejectedMarker = handler.indexOf("QC_JVM_LAUNCH_DISPATCH_REJECTED", accepted);
        int rejected = handler.indexOf("return false;", rejectedMarker);
        assertTrue(jvmDispatch >= 0);
        assertTrue(accepted > jvmDispatch);
        assertTrue(rejectedMarker > accepted);
        assertTrue(rejected > rejectedMarker);

        assertTrue(api.contains(
                "public static boolean launchInstance(Activity activity, MinecraftAccount account,"));
        assertTrue(api.contains("return InstanceHandler.launchInstance(activity, account, instance);"));
        assertTrue(api.contains("public static boolean launchUnattendedLocalTest("));
        assertTrue(api.contains(
                "return InstanceHandler.launchInstance(activity, account, instance, true);"));

        int begin = launcher.indexOf("private void BeginJavaLaunch(PojlibInstance instance)");
        int unattendedCall = launcher.indexOf(
                "launchAccepted = JNIStorage.apiClass.CallStatic<bool>(", begin);
        int unattendedName = launcher.indexOf("\"launchUnattendedLocalTest\"", unattendedCall);
        int normalCall = launcher.indexOf(
                "launchAccepted = JNIStorage.apiClass.CallStatic<bool>(", unattendedName);
        int normalName = launcher.indexOf("\"launchInstance\"", normalCall);
        int rejectionGate = launcher.indexOf("if (!launchAccepted)", normalName);
        int rejectionSignal = launcher.indexOf("launchDispatchFailed = true;", rejectionGate);
        int dispatchedMilestone = launcher.indexOf("QC_AUTOPLAY_LAUNCH_DISPATCHED", rejectionSignal);
        int milestoneCatch = launcher.indexOf("catch (System.Exception exception)", dispatchedMilestone);
        int milestoneFailure = launcher.indexOf(
                "QC_AUTOPLAY_LAUNCH_MILESTONE_FAILED", milestoneCatch);
        int launchCallCatch = launcher.indexOf("catch (System.Exception)", milestoneFailure);
        int launchCallFailure = launcher.indexOf("launchDispatchFailed = true;", launchCallCatch);
        assertTrue(begin >= 0);
        assertTrue(unattendedCall > begin && unattendedName > unattendedCall);
        assertTrue(normalCall > unattendedName && normalName > normalCall);
        assertTrue(rejectionGate > normalName && rejectionSignal > rejectionGate);
        assertTrue(dispatchedMilestone > rejectionSignal);
        assertTrue(milestoneCatch > dispatchedMilestone);
        assertTrue(milestoneFailure > milestoneCatch);
        assertTrue(launchCallCatch > milestoneFailure);
        assertTrue(launchCallFailure > launchCallCatch);
        assertFalse(launcher.substring(milestoneCatch, launchCallCatch).contains(
                "launchDispatchFailed = true;"));
    }

    @Test
    public void preHandoffWaitUsesRealtimeDeadlineAndFailClosedRestart() throws Exception {
        String api = read("src/main/java/pojlib/API.java");
        String launcher = read("../QCXR-XR-Wrapper/Assets/Scripts/InstanceButton.cs");

        assertTrue(launcher.contains(
                "private const float OpenXRHandoffReadyTimeoutSeconds = 240f;"));
        int begin = launcher.indexOf("private void BeginJavaLaunch(PojlibInstance instance)");
        int waiting = launcher.indexOf("waitingForOpenXRHandoff = true;", begin);
        int deadline = launcher.indexOf(
                "Time.realtimeSinceStartup + OpenXRHandoffReadyTimeoutSeconds;", waiting);
        int dispatchThread = launcher.indexOf("new Thread(() =>", deadline);
        assertTrue(begin >= 0);
        assertTrue(waiting > begin);
        assertTrue(deadline > waiting);
        assertTrue(dispatchThread > deadline);

        int update = launcher.indexOf("public void Update()");
        int waitGate = launcher.indexOf(
                "if (waitingForOpenXRHandoff && !openXRHandoffInProgress)", update);
        int readyPoll = launcher.indexOf(
                "GetStatic<bool>(\"gameReady\")", waitGate);
        int pollCatch = launcher.indexOf("catch (System.Exception exception)", readyPoll);
        int pollFailureRestart = launcher.indexOf(
                "RestartAfterOpenXRHandoffWaitFailure(", pollCatch);
        int readyGate = launcher.indexOf("if (gameReady)", pollFailureRestart);
        int handoffClaim = launcher.indexOf("openXRHandoffInProgress = true;", readyGate);
        int handoffStart = launcher.indexOf(
                "StartCoroutine(CompleteOpenXRHandoff());", handoffClaim);
        int timeoutGate = launcher.indexOf(
                "else if (Time.realtimeSinceStartup >= openXRHandoffReadyDeadline", handoffStart);
        int timeoutMarker = launcher.indexOf("QC_OPENXR_HANDOFF_READY_TIMEOUT", timeoutGate);
        int timeoutHandler = launcher.indexOf(
                "private void RestartAfterOpenXRHandoffWaitFailure(string diagnostic)", timeoutMarker);
        int nextMethod = launcher.indexOf("private void TryScheduleUnattendedLaunch()", timeoutHandler);
        String timeoutHandlerBody = launcher.substring(timeoutHandler, nextMethod);
        int stopWaiting = launcher.indexOf("waitingForOpenXRHandoff = false;", timeoutHandler);
        int stopHandoff = launcher.indexOf("openXRHandoffInProgress = false;", stopWaiting);
        int clearDeadline = launcher.indexOf("openXRHandoffReadyDeadline = 0f;", stopHandoff);
        int unsafe = launcher.indexOf("launchStateUnsafe = true;", clearDeadline);
        int abort = launcher.indexOf("AbortConsumedUnattendedRun();", unsafe);
        int restart = launcher.indexOf(
                "JNIStorage.apiClass.CallStatic(\"restartLauncher\", JNIStorage.activity);", abort);
        assertTrue(waitGate > update);
        assertTrue(readyPoll > waitGate);
        assertTrue(pollCatch > readyPoll);
        assertTrue(pollFailureRestart > pollCatch);
        assertTrue(readyGate > pollFailureRestart);
        assertTrue(handoffClaim > readyGate);
        assertTrue(handoffStart > handoffClaim);
        assertTrue(timeoutGate > handoffStart);
        assertTrue(timeoutMarker > timeoutGate);
        assertTrue(timeoutHandler > timeoutMarker);
        assertTrue(nextMethod > timeoutHandler);
        assertTrue(stopWaiting > timeoutHandler);
        assertTrue(stopHandoff > stopWaiting);
        assertTrue(clearDeadline > stopHandoff);
        assertTrue(unsafe > clearDeadline);
        assertTrue(abort > unsafe);
        assertTrue(restart > abort);
        assertFalse(timeoutHandlerBody.contains("CloseXR"));
        assertFalse(timeoutHandlerBody.contains("releaseOpenXRHandoff"));

        int apiRestart = api.indexOf("public static void restartLauncher(Activity activity)");
        int coalescedRestart = api.indexOf(
                "CallbackBridge.restartUnitySession(activity);", apiRestart);
        assertTrue(apiRestart >= 0);
        assertTrue(coalescedRestart > apiRestart);
    }

    @Test
    public void terminalPathsDisarmThePreHandoffDeadline() throws Exception {
        String launcher = read("../QCXR-XR-Wrapper/Assets/Scripts/InstanceButton.cs");

        int dispatchFailure = launcher.indexOf("if (launchDispatchFailed)");
        int dispatchClear = launcher.indexOf("openXRHandoffReadyDeadline = 0f;", dispatchFailure);
        int cleanupGate = launcher.indexOf("if (cleanupSucceeded)", dispatchClear);
        int progressReset = launcher.indexOf("ProgressBarManager.started = false;", cleanupGate);
        int uiReset = launcher.indexOf("uiHandler.KillSetter();", progressReset);
        int watchdogGate = launcher.indexOf(
                "if (waitingForOpenXRHandoff && !openXRHandoffInProgress)", uiReset);
        int complete = launcher.indexOf("private IEnumerator CompleteOpenXRHandoff()");
        int completeClear = launcher.indexOf("openXRHandoffReadyDeadline = 0f;", complete);
        assertTrue(dispatchFailure >= 0);
        assertTrue(dispatchClear > dispatchFailure && dispatchClear < complete);
        assertTrue(cleanupGate > dispatchClear && cleanupGate < complete);
        assertTrue(progressReset > cleanupGate && progressReset < complete);
        assertTrue(uiReset > progressReset && uiReset < complete);
        assertTrue(watchdogGate > uiReset && watchdogGate < complete);
        assertTrue(complete >= 0);
        assertTrue(completeClear > complete);
    }

    private static String read(String path) throws Exception {
        return new String(Files.readAllBytes(Path.of(path)), StandardCharsets.UTF_8);
    }
}
