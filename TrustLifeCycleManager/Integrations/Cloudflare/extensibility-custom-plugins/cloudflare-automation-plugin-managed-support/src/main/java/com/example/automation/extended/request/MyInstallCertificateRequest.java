package com.example.automation.extended.request;

import com.fasterxml.jackson.annotation.JsonIgnoreProperties;

import lombok.Data;

/**
 * Cloudflare-specific fields for an Install-Certificate request.
 */
@Data
@JsonIgnoreProperties(ignoreUnknown = true)
public class MyInstallCertificateRequest {

    /** Explicit id of the Cloudflare custom certificate being replaced (user override); normally blank. */
    private String certificateName;

    /** Discovered-asset identity TLM round-trips from the certificate's alias ({@code <partition>/<id>}). */
    private String virtualServerName;

    /** ISO-8601 flow start date (informational). */
    private String flowStartDate;

    /**
     * Endpoint host the request targets, as discovery reported it (e.g. {@code www.example.com}).
     * Used to find the certificate to replace when the round-tripped alias is stale.
     */
    private String ipAddress;

    /** Subject DN of the cert being installed, mirrors the value used during CSR generation. */
    private String subjectDn;

    /**
     * When true the issuing-CA certificate(s) are appended to the uploaded certificate even for
     * the {@code ubiquitous} / {@code optimal} bundle methods. With {@code force} the ICA is always
     * appended.
     */
    private boolean useCommonIca;
}
