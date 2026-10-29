package com.example.automation.extended.request;

import com.fasterxml.jackson.annotation.JsonIgnoreProperties;

import lombok.Data;

/**
 * Extra fields TLM passes alongside a Generate-CSR request. The SDK populates this object from any
 * JSON fields that are not part of the wrapper {@code GenerateCsrRequest}.
 */
@Data
@JsonIgnoreProperties(ignoreUnknown = true)
public class MyGenerateCertificateRequest {

    /** Explicit Cloudflare custom certificate id the renewal should replace (user override); normally blank. */
    private String certificateName;

    /**
     * Discovered-asset identity TLM round-trips from the certificate's alias, in the form
     * {@code <partition>/<alias>} (e.g. {@code null/7e7b8deb-…}). The segment after the last
     * {@code /} is the Cloudflare custom certificate id that will be replaced at install time.
     */
    private String virtualServerName;

    /** ISO-8601 flow start date (informational). */
    private String flowStartDate;
}
