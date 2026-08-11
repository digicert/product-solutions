package com.example.automation.extended.request;

import lombok.Data;

/**
 * Azure Key Vault-specific fields for a Validate-Certificate request.
 */
@Data
public class MyValidateRequest {

    /** Azure Key Vault certificate name whose active version is being validated. */
    private String certificateName;

    /** Discovered-asset identity TLM round-trips ({@code <partition>/<name>}); the segment after the
     *  last {@code /} is the Key Vault certificate name to validate. */
    private String virtualServerName;

    /** ISO-8601 flow start date, used to namespace the derived certificate name. */
    private String flowStartDate;

    /** Subject DN of the cert being validated. */
    private String subjectDn;
}
