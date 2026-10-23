package com.example.automation.model;

/**
 * Error codes surfaced to TLM as the {@code status} of a {@link com.digicert.tlm.plugin.PluginError}.
 * {@link #CLOUDFLARE_API_ERROR} distinguishes failures reported by the Cloudflare API (non-2xx
 * status, or an envelope whose {@code success} is {@code false}) from unexpected internal faults.
 */
public enum ErrorCode {
    INTERNAL_ERROR,
    UNAUTHORIZED,
    CLOUDFLARE_API_ERROR,
    CSR_GENERATION_ERROR,
    CERTIFICATE_UPLOAD_ERROR,
    CERTIFICATE_ROTATION_ERROR,
    CERTIFICATE_VALIDATION_ERROR
}
