package com.example.automation.model;

import lombok.Data;

/**
 * The active certificate currently held under a Key Vault certificate name, returned as PEM during
 * {@code validateCertificate}.
 */
@Data
public class AzureKeyVaultInstalledCertificate {
    private String certificate;
}
