package com.example.automation.model;

import java.util.List;

import lombok.Data;

/**
 * The PEM-encoded PKCS#10 CSR produced by {@code beginCreateCertificate} against an Azure Key Vault
 * certificate whose issuer is {@code Unknown}. The private key is generated and retained inside the
 * vault; only the CSR leaves Azure.
 */
@Data
public class AzureKeyVaultGeneratedCsr {
    private String csr;
    private List<String> warnings;
}
