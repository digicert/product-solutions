package com.example.automation.extended.request;

import lombok.Data;

@Data
public class MyInstallCertificateRequest {

    /** Full F5 virtual-server path, e.g. {@code partition1/alias1}. */
    private String virtualServerName;

    /** ISO-8601 flow start date, used to namespace the generated key/CSR. */
    private String flowStartDate;

    /** Subject DN of the cert being installed, mirrors the value used during CSR generation. */
    private String subjectDn;

    /** F5 data-plane IP the cert is bound to (used purely for logging). */
    private String ipAddress;

    /** F5 data-plane port the cert is bound to (used purely for logging). */
    private String port;

    /**
     * Re-use the existing client-ssl profile rather than creating a new one. Informational only: TLM has
     * no UI for this on custom plugins, so the connector setting {@code clientSslProfileMode} decides.
     * Nullable so the log can tell "absent" from "false".
     */
    private Boolean updateSameSslProfile;

    /** Save the issuing-CA cert under a shared name so it can be reused across VIPs. */
    private boolean useCommonIca;
}
