package pojlib.install;

import com.google.gson.JsonObject;
import com.google.gson.JsonParser;
import org.junit.Rule;
import org.junit.Test;
import org.junit.rules.TemporaryFolder;

import java.io.File;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertTrue;

public class VivecraftWeaponCollisionMigrationTest {
    @Rule
    public final TemporaryFolder temporaryFolder = new TemporaryFolder();

    @Test
    public void migratesAutoOnceAndPreservesLaterUserChoice() throws Exception {
        File config = temporaryFolder.newFile("vivecraft-client-config.json");
        File backup = new File(temporaryFolder.getRoot(), "vivecraft-client-config.backup.json");
        File marker = new File(temporaryFolder.getRoot(), ".migration-v1");
        write(config, "{\"weaponCollisionNew\":\"AUTO\",\"unknownUserSetting\":17}\n");

        assertEquals(VivecraftWeaponCollisionMigration.Outcome.MIGRATED,
            VivecraftWeaponCollisionMigration.migrate(config, backup, marker));
        assertEquals("ON", read(config).get("weaponCollisionNew").getAsString());
        assertEquals(17, read(config).get("unknownUserSetting").getAsInt());
        assertEquals("AUTO", read(backup).get("weaponCollisionNew").getAsString());
        assertTrue(marker.isFile());

        JsonObject userChoice = read(config);
        userChoice.addProperty("weaponCollisionNew", "OFF");
        write(config, userChoice.toString());
        assertEquals(VivecraftWeaponCollisionMigration.Outcome.ALREADY_APPLIED,
            VivecraftWeaponCollisionMigration.migrate(config, backup, marker));
        assertEquals("OFF", read(config).get("weaponCollisionNew").getAsString());
    }

    @Test
    public void migratesLegacyBooleanAndStringTrue() throws Exception {
        for (String legacyValue : new String[]{"true", "\"true\""}) {
            File directory = temporaryFolder.newFolder("legacy-" + legacyValue.replace('"', 's'));
            File config = new File(directory, "config.json");
            File backup = new File(directory, "backup.json");
            File marker = new File(directory, "marker");
            write(config, "{\"weaponCollisionNew\":" + legacyValue + "}");

            assertEquals(VivecraftWeaponCollisionMigration.Outcome.MIGRATED,
                VivecraftWeaponCollisionMigration.migrate(config, backup, marker));
            assertEquals("ON", read(config).get("weaponCollisionNew").getAsString());
        }
    }

    @Test
    public void canonicalValueIsRecordedWithoutBackupOrRewrite() throws Exception {
        File config = temporaryFolder.newFile("canonical.json");
        File backup = new File(temporaryFolder.getRoot(), "canonical.backup.json");
        File marker = new File(temporaryFolder.getRoot(), "canonical.marker");
        String original = "{ \"weaponCollisionNew\": \"OFF\" }\n";
        write(config, original);

        assertEquals(VivecraftWeaponCollisionMigration.Outcome.RECORDED_UNCHANGED,
            VivecraftWeaponCollisionMigration.migrate(config, backup, marker));
        assertEquals(original, readText(config));
        assertFalse(backup.exists());
        assertTrue(marker.isFile());
    }

    @Test
    public void invalidConfigDoesNotCreateMarkerAndCanRetry() throws Exception {
        File config = temporaryFolder.newFile("invalid.json");
        File backup = new File(temporaryFolder.getRoot(), "invalid.backup.json");
        File marker = new File(temporaryFolder.getRoot(), "invalid.marker");
        write(config, "{not-json");

        assertEquals(VivecraftWeaponCollisionMigration.Outcome.INVALID_CONFIG,
            VivecraftWeaponCollisionMigration.migrate(config, backup, marker));
        assertFalse(marker.exists());
        assertFalse(backup.exists());

        write(config, "{\"weaponCollisionNew\":\"AUTO\"}");
        assertEquals(VivecraftWeaponCollisionMigration.Outcome.MIGRATED,
            VivecraftWeaponCollisionMigration.migrate(config, backup, marker));
    }

    @Test
    public void staleBackupStagingIsRebuiltAndMovedAtomically() throws Exception {
        File config = temporaryFolder.newFile("staged-config.json");
        File backup = new File(temporaryFolder.getRoot(), "staged-config.backup.json");
        File marker = new File(temporaryFolder.getRoot(), "staged-config.marker");
        File staging = new File(backup.getAbsolutePath() + ".questcraft-migration");
        String original = "{\"weaponCollisionNew\":\"AUTO\",\"keep\":42}\n";
        write(config, original);
        write(staging, "partial stale backup");

        assertEquals(VivecraftWeaponCollisionMigration.Outcome.MIGRATED,
            VivecraftWeaponCollisionMigration.migrate(config, backup, marker));

        assertEquals(original, readText(backup));
        assertFalse(staging.exists());
        assertEquals("ON", read(config).get("weaponCollisionNew").getAsString());
    }

    private static JsonObject read(File file) throws Exception {
        return JsonParser.parseString(readText(file)).getAsJsonObject();
    }

    private static String readText(File file) throws Exception {
        return new String(Files.readAllBytes(file.toPath()), StandardCharsets.UTF_8);
    }

    private static void write(File file, String value) throws Exception {
        Files.write(file.toPath(), value.getBytes(StandardCharsets.UTF_8));
    }
}
