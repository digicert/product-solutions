package com.example.automation.extended.request;

import lombok.Data;

/**
 * Azure Key Vault-specific fields for an Install-Certificate request. The signed certificate is
 * merged into the pending certificate operation started during CSR generation, completing it as a
 * new version of {@link #certificateName}.
 */
@Data
public class MyInstallCertificateRequest {

    /**
     * Azure Key Vault certificate name whose pending version the signed certificate is merged into.
     * Must match the name used at CSR generation; derived from the CN/flow when blank.
     */
    private String certificateName;

    /**
     * Discovered-asset identity TLM round-trips from the certificate's alias
     * ({@code <partition>/<name>}). The segment after the last {@code /} is the existing Key Vault
     * certificate name whose pending version the signed certificate is merged into.
     */
    private String virtualServerName;

    /** ISO-8601 flow start date, used to namespace the derived certificate name. */
    private String flowStartDate;

    /** Subject DN of the cert being installed, mirrors the value used during CSR generation. */
    private String subjectDn;

    /** Merge the issuing-CA certificate(s) alongside the end-entity cert so the chain is complete. */
    private boolean useCommonIca;
}
