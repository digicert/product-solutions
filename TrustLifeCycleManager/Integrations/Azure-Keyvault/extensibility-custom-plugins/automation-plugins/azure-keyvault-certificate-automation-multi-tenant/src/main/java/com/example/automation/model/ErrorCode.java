package com.example.automation.model;

/**
 * Error codes surfaced to TLM as the {@code status} of a {@link com.digicert.tlm.plugin.PluginError}.
 * {@link #AZURE_EXCEPTION} distinguishes failures raised by the Azure SDK (auth, throttling, service
 * errors) from unexpected internal faults; the {@code *_NOT_FOUND} / {@link #AMBIGUOUS_TARGET} codes
 * are specific to subscription-wide discovery, where a request has to be pinned to one vault;
 * {@link #CERTIFICATE_NOT_TARGETED} is returned when a request names no existing certificate at all
 * (this plugin only renews / replaces certificates that already exist in a vault).
 */
public enum ErrorCode {
    INTERNAL_ERROR,
    UNAUTHORIZED,
    AZURE_EXCEPTION,
    SUBSCRIPTION_NOT_FOUND,
    VAULT_NOT_FOUND,
    AMBIGUOUS_TARGET,
    CERTIFICATE_NOT_TARGETED,
    CERTIFICATE_CREATION_ERROR,
    CERTIFICATE_MERGE_ERROR,
    CERTIFICATE_VALIDATION_ERROR
}
