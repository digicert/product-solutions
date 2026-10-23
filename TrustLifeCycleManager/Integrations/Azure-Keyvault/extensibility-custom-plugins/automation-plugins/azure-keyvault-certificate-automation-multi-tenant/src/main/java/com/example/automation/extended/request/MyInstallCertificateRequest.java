package com.example.automation.extended.request;

import lombok.Data;

/**
 * Azure Key Vault-specific fields for an Install-Certificate request. The signed certificate is
 * merged into the pending certificate operation started during CSR generation, completing it as a
 * new version of the targeted certificate in the targeted vault.
 */
@Data
public class MyInstallCertificateRequest {

    /** Explicit vault (short name) holding the pending version; optional, see {@link #virtualServerName}. */
    private String vaultName;

    /**
     * Azure Key Vault certificate name whose pending version the signed certificate is merged into
     * (optionally {@code <vault>/<name>}). Must match the name used at CSR generation; optional when the request carries a discovered asset.
     */
    private String certificateName;

    /**
     * Discovered-asset identity TLM round-trips ({@code <vaultName>/<certificateName>}); identifies
     * the vault and the certificate whose pending version the signed certificate is merged into.
     */
    private String virtualServerName;

    /** ISO-8601 flow start date (passed by TLM; not used by this plugin). */
    private String flowStartDate;

    /** Subject DN of the cert being installed, mirrors the value used during CSR generation. */
    private String subjectDn;

    /** Merge the issuing-CA certificate(s) alongside the end-entity cert so the chain is complete. */
    private boolean useCommonIca;
}
