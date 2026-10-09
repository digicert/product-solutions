package com.example.automation.extended.request;

import com.fasterxml.jackson.annotation.JsonIgnoreProperties;

import lombok.Data;

/**
 * FortiGate-specific fields for an Install-Certificate request. The signed certificate is uploaded
 * together with the private key retained during CSR generation, under a new unique name; every
 * reference to the previous certificate (server policy / SNI member / multi-cert group) is then
 * repointed and the previous certificate deleted.
 */
@Data
@JsonIgnoreProperties(ignoreUnknown = true)
public class MyInstallCertificateRequest {

    /** Explicit name of the FortiGate certificate being replaced (user override); normally blank. */
    private String certificateName;

    /**
     * Discovered-asset identity TLM round-trips from the certificate's alias
     * ({@code <partition>/<name>}). The segment after the last {@code /} is the existing FortiGate
     * certificate this install replaces.
     */
    private String virtualServerName;

    /** ISO-8601 flow start date (informational). */
    private String flowStartDate;

    /**
     * Endpoint host the request targets, as discovery reported it (e.g.
     * {@code tlsguru-com-rsa.<fortigateHost>}). Used to find the certificate to replace when the
     * round-tripped alias is stale.
     */
    private String ipAddress;

    /** Subject DN of the cert being installed, mirrors the value used during CSR generation. */
    private String subjectDn;

    /**
     * Include the issuing-CA certificate(s) after the end-entity certificate in the uploaded
     * certificate file. FortiGate reads the first certificate of the file as the local certificate;
     * intermediates are normally configured separately (Intermediate CA / CA group).
     */
    private boolean useCommonIca;
}
