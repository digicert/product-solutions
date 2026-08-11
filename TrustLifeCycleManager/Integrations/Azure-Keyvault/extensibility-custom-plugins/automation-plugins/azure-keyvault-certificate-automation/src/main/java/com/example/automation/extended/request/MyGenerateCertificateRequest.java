package com.example.automation.extended.request;

import lombok.Data;

/**
 * Extra fields TLM passes alongside a Generate-CSR request that are specific to Azure Key Vault. The
 * SDK populates this object from any JSON fields that are not part of the wrapper
 * {@code GenerateCsrRequest}.
 */
@Data
public class MyGenerateCertificateRequest {

    /**
     * Explicit Azure Key Vault certificate name to create or renew. When it matches an existing
     * certificate in the vault, Azure starts a new version of it; when blank, the name is derived
     * from the CN/flow. This is how a customer targets a discovered certificate that has no managed
     * TLM certificate yet — selecting it feeds its existing name back here so a new version is created.
     */
    private String certificateName;

    /**
     * Discovered-asset identity TLM round-trips from the certificate's alias, in the form
     * {@code <partition>/<name>} (e.g. {@code null/selfsigned-certificate}). The segment after the
     * last {@code /} is the existing Key Vault certificate name to renew — reusing it makes Azure
     * create a new version rather than a separate certificate.
     */
    private String virtualServerName;

    /** ISO-8601 flow start date, used to namespace the derived certificate name. */
    private String flowStartDate;
}
