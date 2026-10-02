package pojlib;

import org.junit.Test;

import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;

import static org.junit.Assert.assertTrue;

public class UnityProcessRestartSourceIntegrationTest {
    @Test
    public void restartRequestsAreCoalescedBeforeUnitySchedulesRecreation() throws Exception {
        String bridge = read("src/main/java/org/lwjgl/glfw/CallbackBridge.java");
        int bridgeMethod = bridge.indexOf(
                "public static void restartUnitySession(Activity activity)");
        int cast = bridge.indexOf(
                "UnityPlayerActivity unity = (UnityPlayerActivity) activity;", bridgeMethod);
        int dispatch = bridge.indexOf("unity.reinitUnity();", cast);

        String activity = read("src/main/java/pojlib/UnityPlayerActivity.java");
        int atomic = activity.indexOf("new AtomicBoolean(false)");
        int method = activity.indexOf("public void reinitUnity()", atomic);
        int uiQueue = activity.indexOf("this.runOnUiThread(() -> {", method);
        int claim = activity.indexOf(
                "UNITY_PROCESS_RESTART_REQUESTED.compareAndSet(false, true)", uiQueue);
        int replacement = activity.indexOf("this.startActivity(start);", claim);

        assertTrue(bridgeMethod >= 0);
        assertTrue(cast > bridgeMethod);
        assertTrue(dispatch > cast);
        assertTrue(atomic >= 0);
        assertTrue(method > atomic);
        assertTrue(uiQueue > method);
        assertTrue(claim > uiQueue);
        assertTrue(replacement > claim);
    }

    @Test
    public void schedulingFailureDoesNotStrandOrDuplicateTheRestartLatch() throws Exception {
        String activity = read("src/main/java/pojlib/UnityPlayerActivity.java");
        int method = activity.indexOf("public void reinitUnity()");
        int uiQueue = activity.indexOf("this.runOnUiThread(() -> {", method);
        int claim = activity.indexOf(
                "UNITY_PROCESS_RESTART_REQUESTED.compareAndSet(false, true)", uiQueue);
        int startedFalse = activity.indexOf("boolean replacementStarted = false;", claim);
        int startActivity = activity.indexOf("this.startActivity(start);", startedFalse);
        int startedTrue = activity.indexOf("replacementStarted = true;", startActivity);
        int failureGate = activity.indexOf("if (!replacementStarted)", startedTrue);
        int release = activity.indexOf(
                "UNITY_PROCESS_RESTART_REQUESTED.set(false);", failureGate);
        int outerFailure = activity.indexOf(
                "Could not schedule launcher process recreation.", release);

        assertTrue(uiQueue > method);
        assertTrue(claim > uiQueue);
        assertTrue(startedFalse > claim);
        assertTrue(startActivity > startedFalse);
        assertTrue(startedTrue > startActivity);
        assertTrue(failureGate > startedTrue);
        assertTrue(release > failureGate);
        assertTrue(outerFailure > release);
    }

    @Test
    public void jvmFinallyAlwaysRequestsRecreationAfterSamplerCleanup() throws Exception {
        String jre = read("src/main/java/pojlib/util/JREUtils.java");
        int launch = jre.indexOf("VMLauncher.launchJVM(");
        int outerFinally = jre.indexOf("} finally {", launch);
        int cleanupTry = jre.indexOf("try {", outerFinally);
        int close = jre.indexOf("nativeMemoryMapSampler.close();", cleanupTry);
        int cleanupFinally = jre.indexOf("} finally {", close);
        int restart = jre.indexOf(
                "CallbackBridge.restartUnitySession(activity);", cleanupFinally);

        assertTrue(launch >= 0);
        assertTrue(outerFinally > launch);
        assertTrue(cleanupTry > outerFinally);
        assertTrue(close > cleanupTry);
        assertTrue(cleanupFinally > close);
        assertTrue(restart > cleanupFinally);
    }

    @Test
    public void embeddedJvmShutdownHookRemainsTheNormalRestartPath() throws Exception {
        String jvmBridge = read(
                "jre_lwjgl3glfw/src/main/java/org/lwjgl/glfw/CallbackBridge.java");

        assertTrue(jvmBridge.contains(
                "Runtime.getRuntime().addShutdownHook(new Thread(CallbackBridge::restartUnitySession))"));
        assertTrue(jvmBridge.contains("public static native void restartUnitySession();"));
    }

    private static String read(String path) throws Exception {
        return new String(Files.readAllBytes(Path.of(path)), StandardCharsets.UTF_8);
    }
}
