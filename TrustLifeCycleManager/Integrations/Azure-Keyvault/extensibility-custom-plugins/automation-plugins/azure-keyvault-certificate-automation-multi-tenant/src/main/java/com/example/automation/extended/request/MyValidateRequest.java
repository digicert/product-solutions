package com.example.automation.extended.request;

import lombok.Data;

/**
 * Azure Key Vault-specific fields for a Validate-Certificate request.
 */
@Data
public class MyValidateRequest {

    /** Explicit vault (short name) holding the certificate; optional, see {@link #virtualServerName}. */
    private String vaultName;

    /** Azure Key Vault certificate name whose active version is being validated (optionally {@code <vault>/<name>}). */
    private String certificateName;

    /** Discovered-asset identity TLM round-trips ({@code <vaultName>/<certificateName>}). */
    private String virtualServerName;

    /** ISO-8601 flow start date (passed by TLM; not used by this plugin). */
    private String flowStartDate;

    /** Subject DN of the cert being validated. */
    private String subjectDn;
}
