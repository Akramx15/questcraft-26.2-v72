package pojlib;

import org.junit.Test;

import java.nio.file.Files;
import java.nio.file.Path;

import static org.junit.Assert.assertTrue;

public class OptionsOwnershipPrelaunchSourceIntegrationTest {
    @Test
    public void localOwnershipGateRunsBeforeOnlineOrOfflineBranch() throws Exception {
        String api = new String(Files.readAllBytes(Path.of("src/main/java/pojlib/API.java")));
        int prelaunch = api.indexOf("public static boolean prelaunch(");
        int nextMethod = api.indexOf("public static boolean launchInstance(", prelaunch);
        String body = api.substring(prelaunch, nextMethod);

        int restore = body.indexOf("ModsAbCanaryGate.restorePriorProcessPermit(");
        int ownership = body.indexOf("OptionsOwnershipPrelaunchGate.run(");
        int vivecraftOwnership = body.indexOf(
            "OptionsOwnershipPrelaunchGate.run(new File(", ownership + 1);
        int reconciliation = body.indexOf("instance.reconcileBundledManagedMods(");
        int networkBranch = body.indexOf("if (hasConnection(activity))");
        assertTrue(restore >= 0);
        assertTrue(ownership > restore);
        assertTrue(vivecraftOwnership > ownership);
        assertTrue(reconciliation > vivecraftOwnership);
        assertTrue(networkBranch > reconciliation);
    }

    @Test
    public void ownershipFailureAbortsBeforeNetworkWork() throws Exception {
        String api = new String(Files.readAllBytes(Path.of("src/main/java/pojlib/API.java")));
        int prelaunch = api.indexOf("public static boolean prelaunch(");
        int nextMethod = api.indexOf("public static boolean launchInstance(", prelaunch);
        String body = api.substring(prelaunch, nextMethod);

        int failureGate = body.indexOf("if(!optionsOwnership.mayLaunch())");
        int abort = body.indexOf("return false;", failureGate);
        int networkBranch = body.indexOf("if (hasConnection(activity))");
        assertTrue(failureGate >= 0);
        assertTrue(abort > failureGate);
        assertTrue(networkBranch > abort);
        assertTrue(body.contains(
            "Minecraft options writability check failed; launch aborted safely."));
    }

    @Test
    public void vivecraftSettingsOwnershipFailureAlsoAbortsBeforeModOrNetworkWork()
            throws Exception {
        String api = new String(Files.readAllBytes(Path.of("src/main/java/pojlib/API.java")));
        int prelaunch = api.indexOf("public static boolean prelaunch(");
        int nextMethod = api.indexOf("public static boolean launchInstance(", prelaunch);
        String body = api.substring(prelaunch, nextMethod);

        int configPath = body.indexOf(
            "instance.gameDir, \"config/vivecraft-client-config.json\"");
        int failureGate = body.indexOf("if(!vivecraftOptionsOwnership.mayLaunch())", configPath);
        int abort = body.indexOf("return false;", failureGate);
        int reconciliation = body.indexOf("instance.reconcileBundledManagedMods(");
        int networkBranch = body.indexOf("if (hasConnection(activity))");

        assertTrue(configPath >= 0);
        assertTrue(failureGate > configPath);
        assertTrue(abort > failureGate);
        assertTrue(reconciliation > abort);
        assertTrue(networkBranch > reconciliation);
        assertTrue(body.contains(
            "Vivecraft settings writability check failed; launch aborted safely."));
        assertTrue(body.contains(
            "Repaired Vivecraft settings writability without changing its contents"));
    }
}
