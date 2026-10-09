package com.example.automation.extended.request;

import com.fasterxml.jackson.annotation.JsonIgnoreProperties;

import lombok.Data;

/**
 * FortiWeb-specific fields for a Validate-Certificate request. The installed certificate is located
 * primarily through the flow record written by installCertificate; these fields are fallbacks.
 */
@Data
@JsonIgnoreProperties(ignoreUnknown = true)
public class MyValidateRequest {

    /** Explicit FortiWeb certificate name to validate (user override). */
    private String certificateName;

    /** Discovered-asset identity TLM round-trips ({@code <partition>/<name>}). */
    private String virtualServerName;

    /** ISO-8601 flow start date (informational). */
    private String flowStartDate;

    /** Subject DN of the cert being validated. */
    private String subjectDn;

    /** Serial number (hex) of the certificate TLM issued, when supplied by TLM. */
    private String certificateSerialNumber;
}
