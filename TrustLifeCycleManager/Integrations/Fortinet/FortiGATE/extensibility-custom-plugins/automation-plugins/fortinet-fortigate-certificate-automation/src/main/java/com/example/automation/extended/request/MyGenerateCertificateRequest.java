package com.example.automation.extended.request;

import com.fasterxml.jackson.annotation.JsonIgnoreProperties;

import lombok.Data;

/**
 * Extra fields TLM passes alongside a Generate-CSR request that are specific to FortiGate. The SDK
 * populates this object from any JSON fields that are not part of the wrapper
 * {@code GenerateCsrRequest}.
 */
@Data
@JsonIgnoreProperties(ignoreUnknown = true)
public class MyGenerateCertificateRequest {

    /**
     * Explicit FortiGate local-certificate name the renewal should <em>replace</em> (user override).
     * Normally blank: the discovered asset's name is round-tripped in {@link #virtualServerName}.
     */
    private String certificateName;

    /**
     * Discovered-asset identity TLM round-trips from the certificate's alias, in the form
     * {@code <partition>/<name>} (e.g. {@code null/cer}). The segment after the last {@code /} is
     * the existing FortiGate certificate that will be replaced during installCertificate.
     */
    private String virtualServerName;

    /** ISO-8601 flow start date (informational). */
    private String flowStartDate;
}
