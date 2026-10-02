package org.questcraft.veq.client.config;

/** How the embedded wrist inventory is acquired. */
public enum WristActivationMode {
    /** VEP-style: ray-test the final calibrated panel face and content bounds. */
    VEP_SURFACE_AIM,

    /** Schema 2-5 alias; sanitized to {@link #VEP_SURFACE_AIM}. */
    VEP_AIM
}
