package com.example.automation.model;

/**
 * Error codes surfaced to TLM as the {@code status} of a {@link com.digicert.tlm.plugin.PluginError}.
 * {@link #AZURE_EXCEPTION} distinguishes failures raised by the Azure SDK (auth, throttling, service
 * errors) from unexpected internal faults.
 */
public enum ErrorCode {
    INTERNAL_ERROR,
    UNAUTHORIZED,
    AZURE_EXCEPTION,
    CERTIFICATE_CREATION_ERROR,
    CERTIFICATE_MERGE_ERROR,
    CERTIFICATE_VALIDATION_ERROR
}
