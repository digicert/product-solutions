package com.example.automation.model;

import java.util.ArrayList;
import java.util.List;

import lombok.Data;
import lombok.ToString;

/**
 * Aggregated inventory pulled from an Azure Key Vault during {@code refreshConfiguration}: the vault
 * itself plus every certificate object it holds. Each {@link CertificateAsset} is a discoverable
 * asset a customer can select in TLM; selecting one that has no managed TLM certificate yet drives
 * the "create a new version of the existing certificate" flow (the plugin renews it in place by
 * targeting the same certificate name).
 */
@Data
public class AzureKeyVaultConfigurationData {

    private VaultInfo vaultInfo;
    private List<CertificateAsset> certificates = new ArrayList<>();

    @Data
    public static class VaultInfo {
        /** Marks the endpoint OS name in the TLM inventory. */
        public static final String AZURE_KEY_VAULT = "AZURE_KEY_VAULT";

        /** Full vault URL, e.g. {@code https://myvault.vault.azure.net/}. */
        private String vaultUrl;

        /** Short vault name derived from the URL host, e.g. {@code myvault}. */
        private String vaultName;
    }

    @Data
    @ToString
    public static class CertificateAsset {
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

        /** True when the active version is self-signed (issuer == subject) — a prime replacement candidate. */
        private boolean selfSigned;

        /** ISO-8601 expiry of the active version, or null. */
        private String expiresOn;
    }
}
