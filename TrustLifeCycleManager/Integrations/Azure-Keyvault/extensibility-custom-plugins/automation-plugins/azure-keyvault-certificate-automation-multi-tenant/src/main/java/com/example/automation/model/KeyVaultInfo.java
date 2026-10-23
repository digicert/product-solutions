package com.example.automation.model;

import lombok.Data;

/**
 * One Azure Key Vault discovered in the subscription through Azure Resource Manager. The vault
 * {@code name} is what the plugin round-trips to TLM as the endpoint <em>partition</em>; the
 * {@code vaultUri} is what the data-plane {@code CertificateClient} is built against.
 */
@Data
public class KeyVaultInfo {
    /** Short vault name, e.g. {@code myvault}; unique within the Azure DNS zone. */
    private String name;

    /** Data-plane URI, e.g. {@code https://myvault.vault.azure.net/}. */
    private String vaultUri;

    /** ARM resource id, e.g. {@code /subscriptions/.../providers/Microsoft.KeyVault/vaults/myvault}. */
    private String resourceId;

    /** Resource group the vault lives in. */
    private String resourceGroup;

    /** Azure region, e.g. {@code westeurope}. */
    private String location;

    /** The vault FQDN (host) from the URI, e.g. {@code myvault.vault.azure.net}. */
    public String getHost() {
        if (vaultUri == null || vaultUri.isBlank()) {
            return null;
        }
        var host = vaultUri.replaceFirst("^https?://", "");
        final int slash = host.indexOf('/');
        if (slash >= 0) {
            host = host.substring(0, slash);
        }
        return host.isBlank() ? null : host;
    }
}
