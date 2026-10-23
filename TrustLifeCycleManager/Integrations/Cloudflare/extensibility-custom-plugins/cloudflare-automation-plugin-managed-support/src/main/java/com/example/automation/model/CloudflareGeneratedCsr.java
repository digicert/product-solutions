package com.example.automation.model;

import lombok.Data;

/**
 * A CSR produced during {@code generateCsr}: either by Cloudflare ({@code POST /custom_csrs}, the
 * private key stays in Cloudflare and {@link #customCsrId} is used at upload time) or on the TLM
 * sensor (private key retained in the flow directory, {@link #customCsrId} null).
 */
@Data
public class CloudflareGeneratedCsr {
    private String csr;
    private String customCsrId;
    private String commonName;
    private String keyType;
}
