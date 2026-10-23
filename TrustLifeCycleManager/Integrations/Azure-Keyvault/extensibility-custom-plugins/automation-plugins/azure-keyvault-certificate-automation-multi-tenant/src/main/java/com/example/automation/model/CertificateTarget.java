package com.example.automation.model;

import lombok.AllArgsConstructor;
import lombok.Data;

/**
 * The (vault, certificate name) pair a lifecycle request acts on. Both parts are required: with
 * many vaults behind one connector a certificate name alone is ambiguous.
 */
@Data
@AllArgsConstructor
public class CertificateTarget {
    private KeyVaultInfo vault;
    private String certificateName;

    @Override
    public String toString() {
        return (vault == null ? "?" : vault.getName()) + "/" + certificateName;
    }
}
