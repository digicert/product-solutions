package com.example.automation.adapter;

import java.util.List;

import lombok.Builder;
import lombok.Data;

/**
 * Connection settings for one Azure <em>subscription</em>, built from the TLM connector
 * configuration. Authentication is an Azure AD service principal (client-secret credential);
 * {@code subscriptionId} identifies the subscription whose Key Vaults this connector manages.
 *
 * <p>The optional filters narrow which vaults in the subscription are discovered. All are applied by
 * {@link AzureResourceManagerClient} on the Azure Resource Manager listing, before any vault
 * data-plane call is made.
 */
@Data
@Builder
public class AdapterConfig {
    private String tenantId;
    private String clientId;
    private String clientSecret;

    /** Azure subscription (GUID) whose Key Vaults are managed. */
    private String subscriptionId;

    /** Only discover vaults in these resource groups; empty = every resource group. */
    private List<String> resourceGroups;

    /** Case-insensitive regular expression a vault name must match; null = no name filter. */
    private String vaultNamePattern;

    /** {@code key=value} tag a vault must carry (value may be blank for "key present"); null = none. */
    private String vaultTagFilter;

}
