package pojlib.install;

import java.io.File;
import java.io.IOException;

/**
 * Local, network-independent gate for repairing {@code options.txt} before a
 * Minecraft launch. Expected filesystem failures are converted into an
 * explicit fail-closed decision without exposing the path or file contents.
 */
public final class OptionsOwnershipPrelaunchGate {
    public enum Outcome {
        ABSENT(true, false),
        ALREADY_WRITABLE(true, false),
        REPAIRED(true, true),
        FAILED(false, false);

        private final boolean mayLaunch;
        private final boolean repaired;

        Outcome(boolean mayLaunch, boolean repaired) {
            this.mayLaunch = mayLaunch;
            this.repaired = repaired;
        }

        public boolean mayLaunch() {
            return mayLaunch;
        }

        public boolean repaired() {
            return repaired;
        }
    }

    @FunctionalInterface
    interface RepairOperation {
        OptionsFileOwnershipRepair.Outcome repair(File optionsFile) throws IOException;
    }

    private OptionsOwnershipPrelaunchGate() {
    }

    public static Outcome run(File optionsFile) {
        return run(optionsFile, OptionsFileOwnershipRepair::repair);
    }

    static Outcome run(File optionsFile, RepairOperation operation) {
        if (optionsFile == null || operation == null) {
            return Outcome.FAILED;
        }
        try {
            switch (operation.repair(optionsFile)) {
                case ABSENT:
                    return Outcome.ABSENT;
                case ALREADY_WRITABLE:
                    return Outcome.ALREADY_WRITABLE;
                case REPAIRED:
                    return Outcome.REPAIRED;
                default:
                    return Outcome.FAILED;
            }
        } catch (IOException | SecurityException expectedFilesystemFailure) {
            return Outcome.FAILED;
        }
    }
}
