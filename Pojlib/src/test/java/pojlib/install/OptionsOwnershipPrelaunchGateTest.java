package pojlib.install;

import org.junit.Rule;
import org.junit.Test;
import org.junit.rules.TemporaryFolder;

import java.io.File;
import java.io.IOException;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertTrue;

public class OptionsOwnershipPrelaunchGateTest {
    @Rule
    public final TemporaryFolder temporaryFolder = new TemporaryFolder();

    @Test
    public void repairedOutcomeAllowsLaunchAndReportsRepair() throws Exception {
        File options = temporaryFolder.newFile("options.txt");

        OptionsOwnershipPrelaunchGate.Outcome outcome =
            OptionsOwnershipPrelaunchGate.run(options, ignored ->
                OptionsFileOwnershipRepair.Outcome.REPAIRED);

        assertEquals(OptionsOwnershipPrelaunchGate.Outcome.REPAIRED, outcome);
        assertTrue(outcome.mayLaunch());
        assertTrue(outcome.repaired());
    }

    @Test
    public void injectedRepairFailureAbortsLaunch() throws Exception {
        File options = temporaryFolder.newFile("options.txt");

        OptionsOwnershipPrelaunchGate.Outcome outcome =
            OptionsOwnershipPrelaunchGate.run(options, ignored -> {
                throw new IOException("injected ownership failure");
            });

        assertEquals(OptionsOwnershipPrelaunchGate.Outcome.FAILED, outcome);
        assertFalse(outcome.mayLaunch());
        assertFalse(outcome.repaired());
    }

    @Test
    public void securityFailureAlsoAbortsLaunch() throws Exception {
        File options = temporaryFolder.newFile("options.txt");

        OptionsOwnershipPrelaunchGate.Outcome outcome =
            OptionsOwnershipPrelaunchGate.run(options, ignored -> {
                throw new SecurityException("injected access denial");
            });

        assertEquals(OptionsOwnershipPrelaunchGate.Outcome.FAILED, outcome);
        assertFalse(outcome.mayLaunch());
    }
}
