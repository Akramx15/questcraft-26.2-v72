package org.questcraft.veq.client.quickactions;

import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;

/** Host-only schema-3 preservation checks for the VEP quick-action editor. */
public final class QuickActionPersistenceSelfTest {
    private QuickActionPersistenceSelfTest() {
    }

    public static void main(String[] args) throws Exception {
        Path directory = Files.createTempDirectory("veq-quick-actions-");
        Path file = directory.resolve("quick_actions.json");
        QuickActionManager manager = QuickActionManager.forTest(file);

        manager.setAction(0, QuickActionDefinition.keybind(
                "Inventory", "minecraft:chest", "key.inventory"));
        manager.setAction(1, QuickActionDefinition.keybind(
                "Swap Hand", "minecraft:iron_sword", "key.swapOffhand"));
        manager.setAction(2, QuickActionDefinition.keybind(
                "Big Map", "minecraft:filled_map", "key.xaero_open_map"));
        manager.setAction(3, QuickActionDefinition.keybind(
                "Waypoints", "minecraft:compass", "key.xaero_waypoints"));
        manager.setAction(4, QuickActionDefinition.keybind(
                "New Waypoint", "minecraft:recovery_compass", "key.xaero_new_waypoint"));
        manager.setAction(5, QuickActionDefinition.keybind(
                "Map Settings", "minecraft:map", "key.xaero_minimap_settings"));
        manager.setAction(11, QuickActionDefinition.command(
                "Home", "minecraft:red_bed", "/trigger home"));

        String stored = Files.readString(file, StandardCharsets.UTF_8);
        require(stored.contains("\"version\": 3"), "must preserve schema 3");
        require(count(stored, "\"type\"") == QuickActionManager.SLOT_COUNT,
                "must persist exactly twelve actions");
        require(!stored.contains("/trigger home"), "commands are stored without a chat slash");

        QuickActionManager reloaded = QuickActionManager.forTest(file);
        require(reloaded.getAction(0).displayName().equals("Inventory"),
                "first saved shortcut was lost");
        require(reloaded.getAction(5).value().equals("key.xaero_minimap_settings"),
                "sixth saved shortcut was lost");
        require(reloaded.getAction(11).value().equals("trigger home"),
                "command normalization did not round-trip");
        require(!reloaded.getAction(10).isConfigured(), "empty slots must remain empty");

        reloaded.clearAction(2);
        QuickActionManager cleared = QuickActionManager.forTest(file);
        require(!cleared.getAction(2).isConfigured(), "clear must survive a cold load");
        require(cleared.getAction(3).displayName().equals("Waypoints"),
                "clearing one slot changed a neighboring slot");

        String schemaThree = Files.readString(file, StandardCharsets.UTF_8);
        String futureSchema = schemaThree
                .replaceFirst("\"version\"\\s*:\\s*3", "\"version\": 99")
                .replaceFirst("\\{", "{\n  \"futureMetadata\": {\"preserveMe\": true},");
        Files.writeString(file, futureSchema, StandardCharsets.UTF_8);
        QuickActionManager future = QuickActionManager.forTest(file);
        require(future.isFutureVersionReadOnly(), "future schema must be read-only");
        require(future.getAction(0).displayName().equals("Inventory"),
                "known future-schema fields must remain readable");
        future.clearAction(0);
        require(Files.readString(file, StandardCharsets.UTF_8).equals(futureSchema),
                "future schema or unknown fields were rewritten");

        System.out.println("QuickActionPersistenceSelfTest PASS");
    }

    private static int count(String text, String needle) {
        int result = 0;
        int offset = 0;
        while ((offset = text.indexOf(needle, offset)) >= 0) {
            result++;
            offset += needle.length();
        }
        return result;
    }

    private static void require(boolean condition, String message) {
        if (!condition) {
            throw new AssertionError(message);
        }
    }
}
