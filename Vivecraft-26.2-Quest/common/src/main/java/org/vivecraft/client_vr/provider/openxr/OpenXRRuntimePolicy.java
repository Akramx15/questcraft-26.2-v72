package org.vivecraft.client_vr.provider.openxr;

/**
 * Application-side OpenXR performance policy for the Quest personal build.
 *
 * <p>The runtime (and, when installed, QGO) owns display refresh and processor
 * performance. Vivecraft deliberately makes no refresh-rate or performance-level
 * request so an external dynamic profile is not overridden.</p>
 */
public final class OpenXRRuntimePolicy {

    public static final String REFRESH_RATE_OWNER = "runtime";
    public static final String PERFORMANCE_HINT = "off";

    private OpenXRRuntimePolicy() {}

    public static boolean requestsDisplayRefreshRate() {
        return false;
    }

    public static boolean requestsPerformanceLevel() {
        return false;
    }
}
