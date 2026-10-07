package com.example.automation.extended.request;

import lombok.Data;

/**
 * Extra fields TLM passes alongside a Generate-CSR request that are specific to the F5 BIG-IP. The
 * SDK populates this object from any JSON fields that are not part of the wrapper
 * {@code GenerateCsrRequest}.
 */
@Data
public class MyGenerateCertificateRequest {

    /** Full F5 virtual-server path, e.g. {@code partition1/alias1}. */
    private String virtualServerName;

    /** ISO-8601 flow start date, used to namespace the generated key/CSR. */
    private String flowStartDate;

    /** {@code normal}, {@code fips}, or {@code nethsm}. */
    private String keyStorage;
}
