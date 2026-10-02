package org.questcraft.veq.client.config;

import org.joml.Quaternionf;
import org.joml.Matrix4f;
import org.joml.Vector3f;
import org.vivecraft.client_vr.provider.ControllerType;

import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;

/** Exact legacy backups, per-hand schema-6 migration and transaction contracts. */
public final class WristUiConfigV2MigrationSelfTest {
    private WristUiConfigV2MigrationSelfTest() {
    }

    public static void main(String[] args) throws Exception {
        Path directory = Files.createTempDirectory("veq-config-v6-");
        Path configFile = directory.resolve("wrist_ui.json");
        String v2 = """
                {
                  "version": 2,
                  "enabled": true,
                  "hand": "OFF_HAND",
                  "activationMode": "VEP_AIM",
                  "activationSensitivity": 0.61,
                  "openThreshold": 0.20,
                  "closeThreshold": 0.10,
                  "openDelayMillis": 150,
                  "closeDelayMillis": 150,
                  "scale": 0.57,
                  "offsetX": -0.11,
                  "offsetY": -0.08,
                  "offsetZ": 0.19,
                  "rotationX": 0.10,
                  "rotationY": 0.20,
                  "rotationZ": 0.30,
                  "quickActionDisplayMode": "SIX"
                }
                """;
        Files.writeString(configFile, v2, StandardCharsets.UTF_8);

        WristUiConfig migrated = WristUiConfig.forTest(configFile);
        Path backup = directory.resolve("wrist_ui.json.v2.bak");
        require(Files.isRegularFile(backup), "v2 backup must be created");
        require(Files.readString(backup, StandardCharsets.UTF_8).equals(v2),
                "backup must preserve the exact pre-migration document");
        requireClose(migrated.pose(ControllerType.LEFT).offsetX(), -0.11F,
                "left profile migration");
        requireClose(migrated.pose(ControllerType.RIGHT).offsetX(), 0.07F,
                "unselected right profile gets a mirrored safe default");
        requireClose(migrated.pose(ControllerType.LEFT).scale(), 0.57F,
                "legacy scale migration");
        Quaternionf legacyEffective = new Matrix4f()
                .rotateX(0.10F)
                .rotateY(0.20F)
                .rotateZ(0.30F)
                .getNormalizedRotation(new Quaternionf());
        requireEquivalent(migrated.pose(ControllerType.LEFT), legacyEffective,
                "v2 Rx*Ry*Rz effective orientation must survive migration");
        WristPoseProfile cachedPose = migrated.pose(ControllerType.LEFT);
        require(cachedPose == migrated.pose(ControllerType.LEFT),
                "unchanged per-frame pose reads reuse one immutable snapshot");
        String v6 = Files.readString(configFile, StandardCharsets.UTF_8);
        require(v6.contains("\"version\": 6"), "migrated file must use schema 6");
        require(v6.contains("\"rightPose\""), "schema 6 must persist right pose");
        require(v6.contains("\"leftPose\""), "schema 6 must persist left pose");
        require(v6.contains("\"frontFaceFlipped\": false"),
                "schema 6 must persist an independent face choice");
        require(migrated.activationMode() == WristActivationMode.VEP_SURFACE_AIM,
                "legacy VEP_AIM alias must migrate to final-surface acquisition");

        Path mainFile = directory.resolve("main-wrist.json");
        Files.writeString(
                mainFile,
                v2.replace("\"OFF_HAND\"", "\"MAIN_HAND\"")
                        .replace("\"offsetX\": -0.11", "\"offsetX\": 0.13"),
                StandardCharsets.UTF_8
        );
        WristUiConfig migratedMain = WristUiConfig.forTest(mainFile);
        requireClose(migratedMain.pose(ControllerType.RIGHT).offsetX(), 0.13F,
                "main-hand v2 pose migrates only to right profile");
        requireClose(migratedMain.pose(ControllerType.LEFT).offsetX(), -0.07F,
                "unselected left profile keeps its safe default");
        requireEquivalent(migratedMain.pose(ControllerType.RIGHT), legacyEffective,
                "main-hand migration preserves v2 effective orientation");

        migrated.beginEditing();
        migrated.setOffset(0.25F, 0.26F, 0.27F);
        require(cachedPose != migrated.pose(ControllerType.LEFT),
                "pose mutation invalidates the cached snapshot");
        require(Files.readString(configFile, StandardCharsets.UTF_8).equals(v6),
                "draft must not write before Apply");
        migrated.cancelEditing();
        requireClose(migrated.offsetX(), -0.11F, "Cancel must restore original pose");

        migrated.beginEditing();
        migrated.setOffset(0.21F, 0.22F, 0.23F);
        migrated.applyEditing();
        WristUiConfig reloaded = WristUiConfig.forTest(configFile);
        requireClose(reloaded.offsetX(), 0.21F, "Apply must persist draft");
        requireClose(reloaded.pose(ControllerType.RIGHT).offsetX(), 0.07F,
                "editing left profile must not alter right profile");

        // Fine rotation must be an incremental quaternion operation even at
        // the Euler singularity, not a decompose/recompose round-trip.
        reloaded.beginEditing();
        reloaded.setRotation(0.0F, (float) (Math.PI / 2.0), 0.0F);
        Quaternionf expectedIncrement = new Quaternionf()
                .rotationZYX(0.0F, (float) (Math.PI / 2.0), 0.0F)
                .rotateX((float) Math.toRadians(2.5))
                .normalize();
        reloaded.rotate((float) Math.toRadians(2.5), 0.0F, 0.0F);
        requireEquivalent(reloaded.activePose(), expectedIncrement,
                "incremental fine rotation remains stable at 90 degrees");
        reloaded.cancelEditing();

        Path futureFile = directory.resolve("future.json");
        String future = """
                {
                  "version": 99,
                  "enabled": true,
                  "hand": "OFF_HAND",
                  "futureSentinel": {"mustRemain": true}
                }
                """;
        Files.writeString(futureFile, future, StandardCharsets.UTF_8);
        WristUiConfig futureConfig = WristUiConfig.forTest(futureFile);
        require(futureConfig.isFutureVersionReadOnly(), "future schema must be read-only");
        futureConfig.setScale(0.9F);
        require(Files.readString(futureFile, StandardCharsets.UTF_8).equals(future),
                "future schema and unknown fields must remain byte-for-byte intact");

        Path defaultsFile = directory.resolve("defaults.json");
        WristUiConfig defaults = WristUiConfig.forTest(defaultsFile);
        WristPoseProfile leftDefault = defaults.pose(ControllerType.LEFT);
        WristPoseProfile rightDefault = defaults.pose(ControllerType.RIGHT);
        requireClose(rightDefault.offsetX(), -leftDefault.offsetX(),
                "right default offset mirrors left across local YZ");
        requireClose(rightDefault.offsetY(), leftDefault.offsetY(), "mirrored default Y");
        requireClose(rightDefault.offsetZ(), leftDefault.offsetZ(), "mirrored default Z");
        requireClose(rightDefault.rotationX(), leftDefault.rotationX(), "mirrored quaternion X");
        requireClose(rightDefault.rotationY(), -leftDefault.rotationY(), "mirrored quaternion Y");
        requireClose(rightDefault.rotationZ(), -leftDefault.rotationZ(), "mirrored quaternion Z");
        requireClose(rightDefault.rotationW(), leftDefault.rotationW(), "mirrored quaternion W");

        Path v64File = directory.resolve("v64-pointer-only.json");
        String v64 = """
                {
                  "version": 4,
                  "enabled": true,
                  "hand": "OFF_HAND",
                  "activationMode": "POINTER_ONLY",
                  "activationSensitivity": 0.91,
                  "rightPose": {
                    "offsetX": 0.41,
                    "offsetY": 0.31,
                    "offsetZ": -0.29,
                    "rotationX": 0.1,
                    "rotationY": 0.2,
                    "rotationZ": 0.3,
                    "rotationW": 0.4,
                    "scale": 1.1
                  },
                  "leftPose": {
                    "offsetX": -0.42,
                    "offsetY": 0.32,
                    "offsetZ": -0.28,
                    "rotationX": -0.1,
                    "rotationY": -0.2,
                    "rotationZ": -0.3,
                    "rotationW": 0.4,
                    "scale": 1.2
                  },
                  "showPotionEffects": false,
                  "quickActionDisplayMode": "TWELVE",
                  "radialHotbarEnabled": false
                }
                """;
        Files.writeString(v64File, v64, StandardCharsets.UTF_8);
        WristUiConfig migratedV64 = WristUiConfig.forTest(v64File);
        require(Files.readString(
                        directory.resolve("v64-pointer-only.json.v4.bak"), StandardCharsets.UTF_8).equals(v64),
                "v64 pointer-only document must be archived byte-for-byte");
        require(migratedV64.activationMode() == WristActivationMode.VEP_SURFACE_AIM,
                "v64 pointer-only activation must retire to final-surface aim");
        requireClose(migratedV64.pose(ControllerType.LEFT).offsetX(), -0.42F,
                "v64 left calibrated offset must survive final-face migration");
        requireClose(migratedV64.pose(ControllerType.RIGHT).offsetX(), 0.41F,
                "v64 right calibrated offset must survive final-face migration");
        requireClose(migratedV64.pose(ControllerType.LEFT).scale(), 1.20F,
                "v64 calibrated scale must survive final-face migration");
        requireEquivalent(
                migratedV64.pose(ControllerType.LEFT),
                new Quaternionf(-0.1F, -0.2F, -0.3F, 0.4F).normalize(),
                "v64 quaternion-encoded Flip Face must survive migration"
        );
        require(!migratedV64.showPotionEffects(),
                "non-pose feature choices survive the v64 migration");
        require(migratedV64.quickActionDisplayMode() == QuickActionDisplayMode.TWELVE,
                "quick-action display choice survives the v64 migration");
        require(!migratedV64.radialHotbarEnabled(),
                "Grip enable choice survives the v64 migration");

        Path v5File = directory.resolve("v5-flipped.json");
        String v5Flipped = """
                {
                  "version": 5,
                  "enabled": true,
                  "hand": "OFF_HAND",
                  "activationMode": "VEP_AIM",
                  "activationSensitivity": 0.55,
                  "openThreshold": 0.20,
                  "closeThreshold": 0.10,
                  "openDelayMillis": 150,
                  "closeDelayMillis": 150,
                  "rightPose": {
                    "offsetX": 0.09,
                    "offsetY": -0.07,
                    "offsetZ": 0.18,
                    "rotationX": 0.0,
                    "rotationY": 0.0,
                    "rotationZ": 0.0,
                    "rotationW": 1.0,
                    "scale": 0.48
                  },
                  "leftPose": {
                    "offsetX": -0.12,
                    "offsetY": -0.09,
                    "offsetZ": 0.21,
                    "rotationX": 0.0,
                    "rotationY": 1.0,
                    "rotationZ": 0.0,
                    "rotationW": 0.0,
                    "scale": 0.63
                  },
                  "quickActionDisplayMode": "SIX"
                }
                """;
        Files.writeString(v5File, v5Flipped, StandardCharsets.UTF_8);
        WristUiConfig migratedV5 = WristUiConfig.forTest(v5File);
        require(Files.readString(
                        directory.resolve("v5-flipped.json.v5.bak"), StandardCharsets.UTF_8).equals(v5Flipped),
                "v5 backup must preserve the exact calibrated document");
        requireClose(migratedV5.pose(ControllerType.LEFT).offsetX(), -0.12F,
                "v5 calibrated offset must survive schema 6");
        requireClose(migratedV5.pose(ControllerType.LEFT).scale(), 0.63F,
                "v5 calibrated scale must survive schema 6");
        requireEquivalent(
                migratedV5.pose(ControllerType.LEFT),
                new Quaternionf(0.0F, 1.0F, 0.0F, 0.0F),
                "v5 Flip Face quaternion must survive schema 6"
        );
        require(migratedV5.closeDelayMillis() == 200L,
                "schema 6 upgrades only the old default close dwell to 200 ms");

        WristPoseProfile beforeCancel = migratedV5.pose(ControllerType.LEFT);
        String persistedBeforeDraft = Files.readString(v5File, StandardCharsets.UTF_8);
        migratedV5.beginEditing();
        migratedV5.flipFace(ControllerType.LEFT);
        migratedV5.rotate(0.11F, -0.07F, 0.03F);
        migratedV5.setOffset(0.3F, 0.2F, 0.1F);
        migratedV5.cancelEditing();
        requireEquivalent(
                migratedV5.pose(ControllerType.LEFT),
                beforeCancel.rotation(new Quaternionf()),
                "Cancel must restore the exact pre-edit quaternion/Flip"
        );
        requireClose(migratedV5.pose(ControllerType.LEFT).offsetX(), beforeCancel.offsetX(),
                "Cancel must restore the exact pre-edit offset");
        require(Files.readString(v5File, StandardCharsets.UTF_8).equals(persistedBeforeDraft),
                "Cancel must not write the draft to disk");

        migratedV5.beginEditing();
        migratedV5.flipFace(ControllerType.LEFT);
        Quaternionf expectedFlippedOutput = beforeCancel.rotation(new Quaternionf())
                .rotateY((float) Math.PI)
                .normalize();
        migratedV5.applyEditing();
        WristUiConfig reloadedFlipped = WristUiConfig.forTest(v5File);
        require(reloadedFlipped.frontFaceFlipped(ControllerType.LEFT),
                "Apply/reload must preserve the independent Flip Face flag");
        requireEquivalent(
                reloadedFlipped.pose(ControllerType.LEFT),
                expectedFlippedOutput,
                "Apply/reload must preserve the rendered flipped orientation"
        );

        Quaternionf grabbedRenderedRotation = new Quaternionf()
                .rotationZYX(0.31F, -0.27F, 0.19F)
                .normalize();
        reloadedFlipped.setPose(
                ControllerType.LEFT,
                new Vector3f(-0.08F, -0.06F, 0.17F),
                grabbedRenderedRotation,
                0.58F
        );
        WristUiConfig reloadedGrab = WristUiConfig.forTest(v5File);
        require(reloadedGrab.frontFaceFlipped(ControllerType.LEFT),
                "direct grab must not clear the independent face flag");
        requireEquivalent(
                reloadedGrab.pose(ControllerType.LEFT),
                grabbedRenderedRotation,
                "direct grab must not double-apply Flip Face"
        );

        System.out.println("WristUiConfigV2MigrationSelfTest PASS");
    }

    private static void requireClose(float actual, float expected, String message) {
        if (Math.abs(actual - expected) > 1.0E-4F) {
            throw new AssertionError(message + ": expected=" + expected + ", actual=" + actual);
        }
    }

    private static void requireEquivalent(
            WristPoseProfile actual,
            Quaternionf expected,
            String message
    ) {
        Quaternionf rendered = actual.rotation(new Quaternionf());
        float dot = rendered.x * expected.x
                + rendered.y * expected.y
                + rendered.z * expected.z
                + rendered.w * expected.w;
        if (Math.abs(dot) < 1.0F - 1.0E-5F) {
            throw new AssertionError(message + ": quaternion dot=" + dot);
        }
    }

    private static void require(boolean condition, String message) {
        if (!condition) {
            throw new AssertionError(message);
        }
    }
}
