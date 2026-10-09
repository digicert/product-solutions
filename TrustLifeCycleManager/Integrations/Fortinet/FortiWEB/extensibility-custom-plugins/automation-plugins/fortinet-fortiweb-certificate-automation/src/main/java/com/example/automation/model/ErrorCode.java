package com.example.automation.model;

/**
 * Error codes surfaced to TLM as the {@code status} of a {@link com.digicert.tlm.plugin.PluginError}.
 * {@link #FORTIWEB_API_ERROR} distinguishes failures reported by the FortiWeb REST API (non-2xx
 * status, or a 2xx body carrying a negative {@code errcode}) from unexpected internal faults.
 */
public enum ErrorCode {
    INTERNAL_ERROR,
    UNAUTHORIZED,
    FORTIWEB_API_ERROR,
    CSR_GENERATION_ERROR,
    CERTIFICATE_IMPORT_ERROR,
    CERTIFICATE_ROTATION_ERROR,
    CERTIFICATE_VALIDATION_ERROR
}
