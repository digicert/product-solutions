package com.example.automation.extended.request;

import com.fasterxml.jackson.annotation.JsonIgnoreProperties;

import lombok.Data;

/**
 * Cloudflare-specific fields for a Validate-Certificate request. The installed certificate is
 * located primarily through the flow record written by installCertificate; these are fallbacks.
 */
@Data
@JsonIgnoreProperties(ignoreUnknown = true)
public class MyValidateRequest {

    /** Explicit Cloudflare custom certificate id to validate (user override). */
    private String certificateName;

    /** Discovered-asset identity TLM round-trips ({@code <partition>/<id>}). */
    private String virtualServerName;

    /** ISO-8601 flow start date (informational). */
    private String flowStartDate;

    /** Subject DN of the cert being validated. */
    private String subjectDn;

    /** Serial number (hex) of the certificate TLM issued, when supplied by TLM. */
    private String certificateSerialNumber;

    /** Endpoint host the request targets, as discovery reported it. */
    private String ipAddress;
}
