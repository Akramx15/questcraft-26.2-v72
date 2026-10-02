package org.questcraft.veq.client.quickactions;

/**
 * Persistent, loader-independent description of one VEP quick action.
 *
 * <p>Commands are stored without the leading chat slash. Keybind values are
 * {@link net.minecraft.client.KeyMapping#getName() mapping names}, rather
 * than physical keys, so a later Controls change is respected.</p>
 */
public record QuickActionDefinition(
        QuickActionType type,
        String displayName,
        String iconItemId,
        String value
) {
    public static final int MAX_NAME_LENGTH = 128;
    public static final int MAX_ITEM_ID_LENGTH = 256;
    public static final int MAX_VALUE_LENGTH = 2048;

    public QuickActionDefinition {
        type = type == null ? QuickActionType.EMPTY : type;
        displayName = clean(displayName, MAX_NAME_LENGTH);
        iconItemId = clean(iconItemId, MAX_ITEM_ID_LENGTH);
        value = clean(value, MAX_VALUE_LENGTH);
        if (type == QuickActionType.EMPTY) {
            displayName = "";
            iconItemId = "";
            value = "";
        } else if (type == QuickActionType.COMMAND) {
            value = normalizeCommand(value);
        }
    }

    public static QuickActionDefinition empty() {
        return new QuickActionDefinition(QuickActionType.EMPTY, "", "", "");
    }

    public static QuickActionDefinition command(String displayName,
                                                String iconItemId,
                                                String command) {
        return new QuickActionDefinition(
                QuickActionType.COMMAND,
                displayName,
                iconItemId,
                command
        );
    }

    public static QuickActionDefinition keybind(String displayName,
                                                String iconItemId,
                                                String keyMappingName) {
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

    /** Removes one chat-prefix slash; a double slash retains its second slash. */
    public static String normalizeCommand(String command) {
        String normalized = clean(command, MAX_VALUE_LENGTH);
        return normalized.startsWith("/")
                ? normalized.substring(1).stripLeading()
                : normalized;
    }

    private static String clean(String value, int maximumLength) {
        String cleaned = value == null ? "" : value.strip().replace('\r', ' ').replace('\n', ' ');
        return cleaned.length() > maximumLength ? cleaned.substring(0, maximumLength) : cleaned;
    }
}
