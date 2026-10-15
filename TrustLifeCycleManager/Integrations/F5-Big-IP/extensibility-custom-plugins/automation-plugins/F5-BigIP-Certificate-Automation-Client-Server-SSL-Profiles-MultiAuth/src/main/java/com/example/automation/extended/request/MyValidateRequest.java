package com.example.automation.extended.request;

import lombok.Data;

@Data
public class MyValidateRequest {

    /** Full F5 virtual-server path, e.g. {@code partition1/alias1}. */
    private String virtualServerName;

    /** ISO-8601 flow start date, used to namespace the generated key/CSR. */
    private String flowStartDate;

    /** Subject DN of the cert being validated. */
    private String subjectDn;
}
