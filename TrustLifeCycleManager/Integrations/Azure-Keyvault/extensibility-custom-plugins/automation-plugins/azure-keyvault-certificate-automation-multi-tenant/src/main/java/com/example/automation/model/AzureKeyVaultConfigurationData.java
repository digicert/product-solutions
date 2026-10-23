package com.example.automation.model;

import java.util.ArrayList;
import java.util.List;

import lombok.Data;
import lombok.ToString;

/**
 * Aggregated inventory pulled from every Key Vault in one Azure subscription during
 * {@code refreshConfiguration}: the subscription, the vaults found in it, the certificate objects
 * they hold, and the vaults that could not be read. Each {@link CertificateAsset} is a discoverable
 * asset a customer can select in TLM; selecting one that has no managed TLM certificate yet drives
 * the "create a new version of the existing certificate" flow in <em>its own</em> vault.
 */
@Data
public class AzureKeyVaultConfigurationData {

    /** Marks the endpoint OS name in the TLM inventory. */
    public static final String AZURE_KEY_VAULT = "AZURE_KEY_VAULT";

    private SubscriptionInfo subscriptionInfo;
    private List<KeyVaultInfo> vaults = new ArrayList<>();
    private List<CertificateAsset> certificates = new ArrayList<>();

    /** Vaults listed by ARM whose certificates could not be read (no data-plane access, firewall, …). */
    private List<String> unreachableVaults = new ArrayList<>();

    @Data
    public static class SubscriptionInfo {
        private String subscriptionId;
        /** Display name from ARM when the principal can read it, else the id. */
        private String displayName;
    }

    @Data
    @ToString
    public static class CertificateAsset {
        /** Short name of the vault that holds the certificate; round-tripped as the TLM partition. */
        private String vaultName;

        /** Data-plane URI of that vault. */
        private String vaultUri;

        /** Azure Key Vault certificate object name — the identity used to create a new version. */
        private String name;

        /** SHA-1 X.509 thumbprint (uppercase hex) of the active version, or null. */
        private String thumbprint;

        /** PEM of the active version, or null when it could not be read back. */
        private String certificate;

        /** Subject/CN of the active version, surfaced for cert detail. */
        private String subject;

        /** Whether the certificate is enabled in the vault. */
        private boolean enabled;

        /** True when the active version is self-signed (issuer == subject). */
        private boolean selfSigned;

        /** ISO-8601 expiry of the active version, or null. */
        private String expiresOn;
    }
}
