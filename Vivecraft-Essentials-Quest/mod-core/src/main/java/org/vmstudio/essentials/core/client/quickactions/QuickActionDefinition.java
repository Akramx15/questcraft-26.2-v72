package org.vmstudio.essentials.core.client.quickactions;

import org.jetbrains.annotations.NotNull;

/**
 * Persistent, loader-independent description of one inventory quick action.
 *
 * <p>Commands are stored without Minecraft's leading chat slash. Keybind values
 * are {@link net.minecraft.client.KeyMapping#getName() KeyMapping names}, not
 * physical keys, so a user's later Controls changes are respected.</p>
 */
public record QuickActionDefinition(
        @NotNull QuickActionType type,
        @NotNull String displayName,
        @NotNull String iconItemId,
        @NotNull String value
) {
    public static final int MAX_NAME_LENGTH = 128;
    public static final int MAX_ITEM_ID_LENGTH = 256;
    public static final int MAX_VALUE_LENGTH = 2048;

    public QuickActionDefinition {
        type = type == null ? QuickActionType.EMPTY : type;
        displayName = clean(displayName, MAX_NAME_LENGTH);
        iconItemId = clean(iconItemId, MAX_ITEM_ID_LENGTH);
        value = cleanValue(value, MAX_VALUE_LENGTH);

        if (type == QuickActionType.EMPTY) {
            displayName = "";
            iconItemId = "";
            value = "";
        } else if (type == QuickActionType.COMMAND) {
            value = normalizeCommand(value);
        }
    }

    public static @NotNull QuickActionDefinition empty() {
        return new QuickActionDefinition(QuickActionType.EMPTY, "", "", "");
    }

    public static @NotNull QuickActionDefinition command(@NotNull String displayName,
                                                          @NotNull String iconItemId,
                                                          @NotNull String command) {
        return new QuickActionDefinition(
                QuickActionType.COMMAND,
                displayName,
                iconItemId,
                command
        );
    }

    public static @NotNull QuickActionDefinition keybind(@NotNull String displayName,
                                                          @NotNull String iconItemId,
                                                          @NotNull String keyMappingName) {
        return new QuickActionDefinition(
                QuickActionType.KEYBIND,
                displayName,
                iconItemId,
                keyMappingName
        );
    }

    public boolean isConfigured() {
        return type != QuickActionType.EMPTY && !value.isBlank();
    }

    /** Removes the one chat prefix slash; double-slash commands keep their second slash. */
    public static @NotNull String normalizeCommand(String command) {
        String normalized = cleanValue(command, MAX_VALUE_LENGTH);
        return normalized.startsWith("/") ? normalized.substring(1).stripLeading() : normalized;
    }

    private static @NotNull String clean(String value, int maxLength) {
        String cleaned = value == null ? "" : value.strip();
        cleaned = cleaned.replace('\r', ' ').replace('\n', ' ');
        return truncate(cleaned, maxLength);
    }

    private static @NotNull String cleanValue(String value, int maxLength) {
        String cleaned = value == null ? "" : value.strip();
        // A shortcut always represents one operation. Do not permit pasted
        // line breaks to turn it into several chat submissions.
        cleaned = cleaned.replace('\r', ' ').replace('\n', ' ');
        return truncate(cleaned, maxLength);
    }

    private static @NotNull String truncate(@NotNull String value, int maxLength) {
        return value.length() <= maxLength ? value : value.substring(0, maxLength);
    }
}
