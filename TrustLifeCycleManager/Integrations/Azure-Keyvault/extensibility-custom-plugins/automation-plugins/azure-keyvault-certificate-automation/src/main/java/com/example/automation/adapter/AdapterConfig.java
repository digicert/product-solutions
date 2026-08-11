package com.example.automation.adapter;

import lombok.Builder;
import lombok.Data;

/**
 * Connection settings for a single Azure Key Vault, built from the TLM connector configuration.
 * Authentication is an Azure AD service principal (client-secret credential); {@code vaultUrl}
 * identifies the one vault this connector manages.
 */
@Data
@Builder
public class AdapterConfig {
    private String tenantId;
    private String clientId;
    private String clientSecret;
    private String vaultUrl;
}
