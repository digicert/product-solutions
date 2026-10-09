package com.example.automation.model;

/**
 * Error codes surfaced to TLM as the {@code status} of a {@link com.digicert.tlm.plugin.PluginError}.
 * {@link #FORTIGATE_API_ERROR} distinguishes failures reported by the FortiOS REST API (non-2xx
 * status, or a body whose {@code status} is {@code error}) from unexpected internal faults.
 */
public enum ErrorCode {
    INTERNAL_ERROR,
    UNAUTHORIZED,
    FORTIGATE_API_ERROR,
    CSR_GENERATION_ERROR,
    CERTIFICATE_IMPORT_ERROR,
    CERTIFICATE_ROTATION_ERROR,
    CERTIFICATE_VALIDATION_ERROR
}
