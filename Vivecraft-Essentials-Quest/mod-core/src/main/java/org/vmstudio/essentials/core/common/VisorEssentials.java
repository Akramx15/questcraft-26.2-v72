package org.vmstudio.essentials.core.common;

import org.vmstudio.essentials.core.server.EssentialsServer;

public abstract class VisorEssentials {
    public static final String MOD_ID = "visor_essentials";
    public static final String MOD_NAME = "VisorEssentialsPlus";

    public static EssentialsServer SERVER;

    /** Compatibility hook retained for addons that temporarily replace the wrist inventory. */
    public static boolean customInventory = true;
}
