package pojlib.install;

import com.google.gson.GsonBuilder;
import com.google.gson.JsonElement;
import com.google.gson.JsonObject;
import com.google.gson.JsonParser;

import java.io.File;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.AtomicMoveNotSupportedException;
import java.nio.file.FileAlreadyExistsException;
import java.nio.file.Files;
import java.nio.file.StandardCopyOption;

/** One-shot repair for the personal 26.2 profile's invalid collision seed. */
public final class VivecraftWeaponCollisionMigration {
    public enum Outcome {
        ALREADY_APPLIED,
        CONFIG_MISSING,
        INVALID_CONFIG,
        MIGRATED,
        RECORDED_UNCHANGED
    }

    private static final String PROPERTY = "weaponCollisionNew";

    private VivecraftWeaponCollisionMigration() {
    }

    /**
     * Migrates the legacy string/boolean {@code true} and the old {@code AUTO}
     * personal default to the canonical enum value {@code ON}. Once the marker
     * exists, later user choices are never changed.
     */
    public static Outcome migrate(File configFile, File backupFile, File markerFile) throws IOException {
        if (markerFile.isFile()) {
            return Outcome.ALREADY_APPLIED;
        }
        if (!configFile.isFile()) {
            return Outcome.CONFIG_MISSING;
        }

        JsonElement parsed;
        try {
            parsed = JsonParser.parseString(
                new String(Files.readAllBytes(configFile.toPath()), StandardCharsets.UTF_8));
        } catch (RuntimeException invalidJson) {
            return Outcome.INVALID_CONFIG;
        }
        if (!parsed.isJsonObject()) {
            return Outcome.INVALID_CONFIG;
        }

        JsonObject config = parsed.getAsJsonObject();
        JsonElement current = config.get(PROPERTY);
        boolean migrate = current != null && current.isJsonPrimitive() &&
            (current.getAsJsonPrimitive().isBoolean() && current.getAsBoolean() ||
                current.getAsJsonPrimitive().isString() &&
                    ("true".equalsIgnoreCase(current.getAsString().trim()) ||
                        "auto".equalsIgnoreCase(current.getAsString().trim())));

        if (migrate) {
            backupAtomicallyIfAbsent(configFile, backupFile);
            config.addProperty(PROPERTY, "ON");
            String serialized = new GsonBuilder().setPrettyPrinting().create().toJson(config) + "\n";
            writeAtomically(configFile, serialized);
        }

        writeAtomically(markerFile, "v1\n");
        return migrate ? Outcome.MIGRATED : Outcome.RECORDED_UNCHANGED;
    }

    private static void backupAtomicallyIfAbsent(File source, File destination) throws IOException {
        File parent = destination.getParentFile();
        if (parent != null) {
            Files.createDirectories(parent.toPath());
        }
        if (destination.exists()) {
            return;
        }

        File staged = stagingFile(destination);
        // A previous launch may have stopped between the staged copy and move.
        // Never trust that partial file; recreate it from the current source.
        Files.deleteIfExists(staged.toPath());
        try {
            Files.copy(source.toPath(), staged.toPath());
            try {
                moveWithoutReplacing(staged, destination);
            } catch (FileAlreadyExistsException ignored) {
                // Another launch won the race. Preserve its original backup.
            }
        } finally {
            Files.deleteIfExists(staged.toPath());
        }
    }

    private static void moveWithoutReplacing(File staged, File destination) throws IOException {
        try {
            Files.move(staged.toPath(), destination.toPath(), StandardCopyOption.ATOMIC_MOVE);
        } catch (AtomicMoveNotSupportedException ignored) {
            Files.move(staged.toPath(), destination.toPath());
        }
    }

    private static void writeAtomically(File destination, String contents) throws IOException {
        File parent = destination.getParentFile();
        if (parent != null) {
            Files.createDirectories(parent.toPath());
        }
        File staged = stagingFile(destination);
        Files.write(staged.toPath(), contents.getBytes(StandardCharsets.UTF_8));
        try {
            Files.move(staged.toPath(), destination.toPath(),
                StandardCopyOption.ATOMIC_MOVE, StandardCopyOption.REPLACE_EXISTING);
        } catch (AtomicMoveNotSupportedException ignored) {
            Files.move(staged.toPath(), destination.toPath(), StandardCopyOption.REPLACE_EXISTING);
        } finally {
            Files.deleteIfExists(staged.toPath());
        }
    }

    private static File stagingFile(File destination) {
        return new File(destination.getAbsolutePath() + ".questcraft-migration");
    }
}
