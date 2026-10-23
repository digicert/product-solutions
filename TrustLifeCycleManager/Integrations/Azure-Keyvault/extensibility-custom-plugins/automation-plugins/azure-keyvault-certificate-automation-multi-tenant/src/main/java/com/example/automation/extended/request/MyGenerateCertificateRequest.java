package com.example.automation.extended.request;

import lombok.Data;

/**
 * Extra fields TLM passes alongside a Generate-CSR request that are specific to Azure Key Vault.
 * With many vaults behind one connector, the target is a (vault, certificate name) pair.
 */
@Data
public class MyGenerateCertificateRequest {

    /**
     * Explicit vault (short name, e.g. {@code myvault}) to create or renew the certificate in.
     * Optional: a discovered asset already carries its vault in {@link #virtualServerName}.
     */
    private String vaultName;

    /**
     * Explicit Azure Key Vault certificate name to create or renew. May also be written as
     * {@code <vault>/<name>}. When it matches an existing certificate in the vault, Azure starts a
     * new version of it. Optional when the request carries a discovered asset.
     */
    private String certificateName;

    /**
     * Discovered-asset identity TLM round-trips from the endpoint's partition and alias, in the form
     * {@code <vaultName>/<certificateName>} (e.g. {@code myvault/selfsigned-certificate}). The part
     * before the last {@code /} is the vault, the part after it the existing certificate name to
     * renew — reusing it makes Azure create a new version rather than a separate certificate.
     */
    private String virtualServerName;

    /** ISO-8601 flow start date (passed by TLM; not used by this plugin). */
    private String flowStartDate;
}
