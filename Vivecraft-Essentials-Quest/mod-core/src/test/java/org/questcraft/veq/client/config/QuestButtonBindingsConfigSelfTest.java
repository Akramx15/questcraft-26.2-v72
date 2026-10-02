package org.questcraft.veq.client.config;

import org.questcraft.veq.client.input.QuestButtonAction;
import org.questcraft.veq.client.input.QuestFaceButton;

import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;

public final class QuestButtonBindingsConfigSelfTest {
    private QuestButtonBindingsConfigSelfTest() {
    }

    public static void main(String[] args) throws Exception {
        Path directory = Files.createTempDirectory("veq-quest-controls-");
        Path file = directory.resolve("quest_button_bindings.json");

        QuestButtonBindingsConfig config = QuestButtonBindingsConfig.forTest(file);
        require(config.action(QuestFaceButton.LEFT_Y) == QuestButtonAction.ATTACK_BREAK_THIS_HAND,
                "personal default maps Y to Attack/Break");
        require(config.action(QuestFaceButton.RIGHT_B) == QuestButtonAction.MAIN_HAND_USE,
                "personal default preserves B main-hand use");
        config.markAppliedToOpenXR();
        require(!config.restartRequired(), "fresh OpenXR snapshot matches config");

        config.beginEditing();
        config.setAction(QuestFaceButton.RIGHT_B, QuestButtonAction.ATTACK_BREAK_THIS_HAND);
        require(config.action(QuestFaceButton.RIGHT_B) == QuestButtonAction.ATTACK_BREAK_THIS_HAND &&
                        config.action(QuestFaceButton.LEFT_Y) == QuestButtonAction.NONE,
                "moving Attack to another button clears its previous physical source");
        config.setAction(QuestFaceButton.RIGHT_B, QuestButtonAction.MAIN_HAND_USE);
        config.setAction(QuestFaceButton.RIGHT_A, QuestButtonAction.MAIN_HAND_USE);
        require(config.action(QuestFaceButton.RIGHT_A) == QuestButtonAction.MAIN_HAND_USE &&
                        config.action(QuestFaceButton.RIGHT_B) == QuestButtonAction.NONE,
                "moving routed Main Use also keeps one unambiguous source");
        config.cancelEditing();

        config.beginEditing();
        config.setAction(QuestFaceButton.LEFT_Y, QuestButtonAction.INVENTORY);
        require(config.restartRequired(), "draft reports restart requirement");
        config.cancelEditing();
        require(config.action(QuestFaceButton.LEFT_Y) == QuestButtonAction.ATTACK_BREAK_THIS_HAND,
                "Cancel restores exact layout");
        require(!config.restartRequired(), "Cancel clears restart requirement");

        config.beginEditing();
        config.setAction(QuestFaceButton.LEFT_Y, QuestButtonAction.INVENTORY);
        require(config.applyEditing(), "Apply reports a successful save");
        require(Files.isRegularFile(file), "Apply persists config");
        require(config.restartRequired(), "saved change waits for OpenXR restart");

        QuestButtonBindingsConfig reloaded = QuestButtonBindingsConfig.forTest(file);
        require(reloaded.action(QuestFaceButton.LEFT_Y) == QuestButtonAction.INVENTORY,
                "saved layout reloads");

        Path blockedFile = directory.resolve("blocked-bindings");
        Files.createDirectory(blockedFile);
        QuestButtonBindingsConfig retryable = QuestButtonBindingsConfig.forTest(blockedFile);
        retryable.beginEditing();
        retryable.setAction(QuestFaceButton.LEFT_Y, QuestButtonAction.INVENTORY);
        require(!retryable.applyEditing(), "Apply reports persistence failure");
        Files.delete(blockedFile);
        require(retryable.applyEditing(), "failed Apply keeps the transaction retryable");
        require(Files.isRegularFile(blockedFile), "retry persists the retained draft");
        QuestButtonBindingsConfig retried = QuestButtonBindingsConfig.forTest(blockedFile);
        require(retried.action(QuestFaceButton.LEFT_Y) == QuestButtonAction.INVENTORY,
                "retry saved the original draft instead of discarding it");

        String legacy = "{\n" +
                "  \"version\": 1,\n" +
                "  \"leftX\": \"TELEPORT\",\n" +
                "  \"leftY\": \"ATTACK_BREAK\",\n" +
                "  \"rightA\": \"JUMP\",\n" +
                "  \"rightB\": \"MAIN_HAND_USE\"\n" +
                "}\n";
        Files.writeString(file, legacy, StandardCharsets.UTF_8);
        QuestButtonBindingsConfig migrated = QuestButtonBindingsConfig.forTest(file);
        require(migrated.action(QuestFaceButton.LEFT_Y) ==
                        QuestButtonAction.ATTACK_BREAK_THIS_HAND,
                "v1 Attack/Break migrates to source-hand routing");
        require(Files.readString(file, StandardCharsets.UTF_8).contains(
                        "\"leftY\": \"ATTACK_BREAK_THIS_HAND\""),
                "migration writes the unambiguous v2 action name");

        String future = "{\n" +
                "  \"version\": 99,\n" +
                "  \"leftX\": \"TELEPORT\",\n" +
                "  \"leftY\": \"ATTACK_BREAK_THIS_HAND\",\n" +
                "  \"rightA\": \"JUMP\",\n" +
                "  \"rightB\": \"MAIN_HAND_USE\",\n" +
                "  \"futureField\": true\n" +
                "}\n";
        Files.writeString(file, future, StandardCharsets.UTF_8);
        QuestButtonBindingsConfig readOnly = QuestButtonBindingsConfig.forTest(file);
        require(readOnly.isFutureVersionReadOnly(), "future schema is read-only");
        readOnly.setAction(QuestFaceButton.LEFT_Y, QuestButtonAction.INVENTORY);
        require(Files.readString(file, StandardCharsets.UTF_8).equals(future),
                "future schema and unknown fields stay byte-identical");
    }

    private static void require(boolean condition, String message) {
        if (!condition) {
            throw new AssertionError(message);
        }
    }
}
