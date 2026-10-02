package org.questcraft.veq.client.config;

import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;

/** Host-only persistence and migration checks for the wrist feature source of truth. */
public final class VepFeatureConfigSelfTest {
    private VepFeatureConfigSelfTest() {
    }

    public static void main(String[] args) throws Exception {
        Path directory = Files.createTempDirectory("veq-feature-config-");
        Path file = directory.resolve("wrist_features.json");
        VepFeatureConfig config = VepFeatureConfig.forTest(file);

        require(config.quickActionDisplayMode() == QuickActionDisplayMode.SIX,
                "six quick actions must be the safe default");
        require(config.showPotionEffects(), "potion effects must default on");
        require(config.showStatusHud(), "status HUD must default on");
        require(!config.showPlayerPreview(), "Quest player preview must default off");
        require(config.creativeWrist(), "creative wrist must default on");
        require(!config.contextualContainers(), "context containers must fail open to native screens");
        require(config.xaeroIntegration(), "Xaero integration must default on");
        require(config.jeiIntegration(), "JEI integration must default on");
        require(config.inventoryProfilesIntegration(), "IPN integration must default on");

        verifyCancelRestoresDraft(config, file);
        verifyApplyPersistsEveryFeature(config, file);
        verifyOlderSchemaMigration(directory.resolve("older.json"));
        verifySchemaOneContextualMigration(directory.resolve("schema-one.json"));
        verifySchemaTwoPreviewMigration(directory.resolve("schema-two.json"));
        verifyBackupFailureDoesNotRewrite(directory.resolve("backup-failure.json"));
        verifyFutureSchemaPreservation(directory.resolve("future.json"));

        System.out.println("VepFeatureConfigSelfTest PASS");
    }

    private static void verifyCancelRestoresDraft(VepFeatureConfig config, Path file) throws Exception {
        String before = Files.readString(file, StandardCharsets.UTF_8);
        long revision = config.revision();

        config.beginEditing();
        config.setQuickActionDisplayMode(QuickActionDisplayMode.TWELVE);
        config.setShowPotionEffects(false);
        config.setShowStatusHud(false);
        config.setShowPlayerPreview(true);
        config.setCreativeWrist(false);
        config.setContextualContainers(true);
        config.setIntegration(VepFeatureConfig.OptionalIntegration.XAERO, false);
        config.setIntegration(VepFeatureConfig.OptionalIntegration.JEI, false);
        config.setIntegration(VepFeatureConfig.OptionalIntegration.INVENTORY_PROFILES_NEXT, false);
        config.setStatusVisible(VepFeatureConfig.StatusMetric.ARMOR, false);
        config.setStatusPosition(
                VepFeatureConfig.StatusMetric.HUNGER,
                VepFeatureConfig.StatusPosition.TOP
        );

        require(config.quickActionDisplayMode() == QuickActionDisplayMode.TWELVE,
                "quick-action draft was not visible to rendering");
        require(!config.showPotionEffects(), "potion draft was not visible to rendering");
        require(!config.showStatusHud(), "status draft was not visible to rendering");
        require(config.showPlayerPreview(), "player-preview draft was not visible to rendering");
        require(!config.creativeWrist(), "creative draft was not visible to rendering");
        require(config.contextualContainers(), "context draft was not visible to rendering");
        require(!config.xaeroIntegration(), "Xaero draft was not visible to rendering");
        require(!config.jeiIntegration(), "JEI draft was not visible to rendering");
        require(!config.inventoryProfilesIntegration(), "IPN draft was not visible to rendering");
        require(Files.readString(file, StandardCharsets.UTF_8).equals(before),
                "live preview wrote feature settings before Apply");

        config.cancelEditing();
        require(config.quickActionDisplayMode() == QuickActionDisplayMode.SIX,
                "Cancel did not restore quick actions");
        require(config.showPotionEffects(), "Cancel did not restore potion effects");
        require(config.showStatusHud(), "Cancel did not restore the status HUD");
        require(!config.showPlayerPreview(), "Cancel did not restore player preview");
        require(config.creativeWrist(), "Cancel did not restore creative wrist");
        require(!config.contextualContainers(), "Cancel did not restore context containers");
        require(config.xaeroIntegration(), "Cancel did not restore Xaero");
        require(config.jeiIntegration(), "Cancel did not restore JEI");
        require(config.inventoryProfilesIntegration(), "Cancel did not restore IPN");
        require(config.statusVisible(VepFeatureConfig.StatusMetric.ARMOR),
                "Cancel did not restore status visibility");
        require(config.statusPosition(VepFeatureConfig.StatusMetric.HUNGER)
                        == VepFeatureConfig.StatusPosition.BOTTOM,
                "Cancel did not restore status position");
        require(config.revision() > revision, "Cancel did not invalidate the live preview");
        require(Files.readString(file, StandardCharsets.UTF_8).equals(before),
                "Cancel rewrote the feature settings file");
    }

    private static void verifyApplyPersistsEveryFeature(VepFeatureConfig config, Path file)
            throws Exception {
        config.beginEditing();

        config.setQuickActionDisplayMode(QuickActionDisplayMode.TWELVE);
        config.setShowPotionEffects(false);
        config.setShowStatusHud(false);
        config.setShowPlayerPreview(true);
        config.setCreativeWrist(false);
        config.setContextualContainers(true);
        config.setIntegration(VepFeatureConfig.OptionalIntegration.XAERO, false);
        config.setIntegration(VepFeatureConfig.OptionalIntegration.JEI, false);
        config.setIntegration(VepFeatureConfig.OptionalIntegration.INVENTORY_PROFILES_NEXT, false);
        config.setStatusVisible(VepFeatureConfig.StatusMetric.ARMOR, false);
        config.setStatusPosition(
                VepFeatureConfig.StatusMetric.HUNGER,
                VepFeatureConfig.StatusPosition.TOP
        );

        String beforeApply = Files.readString(file, StandardCharsets.UTF_8);
        config.applyEditing();

        String stored = Files.readString(file, StandardCharsets.UTF_8);
        require(!stored.equals(beforeApply), "Apply did not persist the feature transaction");
        require(stored.contains("\"version\": 3"), "feature schema was not written");
        VepFeatureConfig reloaded = VepFeatureConfig.forTest(file);
        require(reloaded.quickActionDisplayMode() == QuickActionDisplayMode.TWELVE,
                "twelve-button choice did not survive reload");
        require(!reloaded.showPotionEffects(), "potion toggle did not survive reload");
        require(!reloaded.showStatusHud(), "status HUD toggle did not survive reload");
        require(reloaded.showPlayerPreview(), "player-preview toggle did not survive reload");
        require(!reloaded.creativeWrist(), "creative toggle did not survive reload");
        require(reloaded.contextualContainers(), "context opt-in did not survive reload");
        require(!reloaded.statusVisible(VepFeatureConfig.StatusMetric.ARMOR),
                "metric visibility did not survive reload");
        require(reloaded.statusPosition(VepFeatureConfig.StatusMetric.HUNGER)
                        == VepFeatureConfig.StatusPosition.TOP,
                "metric position did not survive reload");
        require(!reloaded.jeiIntegration(), "optional-integration toggle did not survive reload");
        require(!reloaded.xaeroIntegration(), "Xaero toggle did not survive reload");
        require(!reloaded.inventoryProfilesIntegration(), "IPN toggle did not survive reload");
    }

    private static void verifyOlderSchemaMigration(Path file) throws Exception {
        Files.writeString(file, """
                {
                  "version": 0,
                  "quickActionDisplayMode": "TWELVE",
                  "showPotionEffects": false,
                  "showStatusHud": false,
                  "xaeroIntegration": false
                }
                """, StandardCharsets.UTF_8);
        VepFeatureConfig migrated = VepFeatureConfig.forTest(file);
        require(migrated.quickActionDisplayMode() == QuickActionDisplayMode.TWELVE,
                "older quick-action value was not migrated");
        require(!migrated.showPotionEffects(), "older potion value was not migrated");
        require(!migrated.showStatusHud(), "older status value was not migrated");
        require(!migrated.xaeroIntegration(), "older integration value was not migrated");
        require(migrated.creativeWrist(), "missing older fields need safe defaults");
        String rewritten = Files.readString(file, StandardCharsets.UTF_8);
        require(rewritten.contains("\"version\": 3"), "older schema was not upgraded once");
        require(rewritten.contains("\"inventoryProfilesIntegration\": true"),
                "migration did not materialize safe defaults");
        require(!migrated.contextualContainers(),
                "older schemas must migrate to the native-screen fallback");
        require(Files.isRegularFile(file.resolveSibling("older.json.v0.bak")),
                "older feature schema was not backed up before migration");
    }

    private static void verifySchemaOneContextualMigration(Path file) throws Exception {
        String schemaOne = """
                {
                  "version": 1,
                  "contextualContainers": true,
                  "showPotionEffects": true
                }
                """;
        Files.writeString(file, schemaOne, StandardCharsets.UTF_8);
        VepFeatureConfig migrated = VepFeatureConfig.forTest(file);

        require(!migrated.contextualContainers(),
                "schema-1 implicit contextual capture must migrate off");
        require(Files.readString(
                        file.resolveSibling("schema-one.json.v1.bak"), StandardCharsets.UTF_8)
                        .equals(schemaOne),
                "schema-1 backup did not preserve the exact previous config");
        String rewritten = Files.readString(file, StandardCharsets.UTF_8);
        require(rewritten.contains("\"version\": 3"),
                "schema-1 config was not upgraded to schema 3");
        require(rewritten.contains("\"contextualContainers\": false"),
                "schema-1 migration did not persist the native-screen fallback");
    }

    private static void verifySchemaTwoPreviewMigration(Path file) throws Exception {
        String schemaTwo = """
                {
                  "version": 2,
                  "contextualContainers": true,
                  "showStatusHud": true
                }
                """;
        Files.writeString(file, schemaTwo, StandardCharsets.UTF_8);
        VepFeatureConfig migrated = VepFeatureConfig.forTest(file);

        require(migrated.contextualContainers(),
                "schema-2 explicit contextual choice must survive schema-3 migration");
        require(!migrated.showPlayerPreview(),
                "schema-2 migration must default the expensive Quest preview off");
        require(Files.readString(
                        file.resolveSibling("schema-two.json.v2.bak"), StandardCharsets.UTF_8)
                        .equals(schemaTwo),
                "schema-2 backup did not preserve the exact previous config");
        String rewritten = Files.readString(file, StandardCharsets.UTF_8);
        require(rewritten.contains("\"version\": 3"),
                "schema-2 config was not upgraded to schema 3");
        require(rewritten.contains("\"showPlayerPreview\": false"),
                "schema-2 migration did not persist the safe preview default");
    }

    private static void verifyBackupFailureDoesNotRewrite(Path file) throws Exception {
        String schemaOne = """
                {
                  "version": 1,
                  "contextualContainers": true
                }
                """;
        Files.writeString(file, schemaOne, StandardCharsets.UTF_8);
        Path blockedBackup = file.resolveSibling("backup-failure.json.v1.bak");
        Files.createDirectory(blockedBackup);

        VepFeatureConfig migrated = VepFeatureConfig.forTest(file);

        require(!migrated.contextualContainers(),
                "failed backup must still fail open in memory");
        require(Files.readString(file, StandardCharsets.UTF_8).equals(schemaOne),
                "migration rewrote the source config without a safe backup");
        require(Files.isDirectory(blockedBackup),
                "migration replaced an unsafe backup target");
    }

    private static void verifyFutureSchemaPreservation(Path file) throws Exception {
        String future = """
                {
                  "version": 99,
                  "quickActionDisplayMode": "TWELVE",
                  "showPotionEffects": false,
                  "futureFeature": {
                    "unknown": "preserve exactly"
                  }
                }
                """;
        Files.writeString(file, future, StandardCharsets.UTF_8);
        VepFeatureConfig config = VepFeatureConfig.forTest(file);
        require(config.isFutureVersionReadOnly(), "future schema was not made read-only");
        require(config.quickActionDisplayMode() == QuickActionDisplayMode.TWELVE,
                "known future-schema values should remain readable");
        require(!config.showPotionEffects(), "known future potion value was not read");

        config.beginEditing();
        config.setQuickActionDisplayMode(QuickActionDisplayMode.SIX);
        config.setShowPotionEffects(true);
        config.setShowStatusHud(false);
        config.setShowPlayerPreview(true);
        config.setCreativeWrist(false);
        config.setContextualContainers(false);
        config.setIntegration(VepFeatureConfig.OptionalIntegration.XAERO, false);
        config.applyEditing();

        require(config.quickActionDisplayMode() == QuickActionDisplayMode.TWELVE,
                "an older build mutated future quick-action state");
        require(!config.showPotionEffects(), "an older build mutated future potion state");
        require(Files.readString(file, StandardCharsets.UTF_8).equals(future),
                "future schema or unknown fields were rewritten");
    }

    private static void require(boolean condition, String message) {
        if (!condition) {
            throw new AssertionError(message);
        }
    }
}
