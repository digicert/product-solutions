/**
 * Configuration class for the DigiCert TLM Automation Plugin (Azure Key Vault, subscription scope).
 * <p>
 * Holds the parameters required to authenticate with Azure Active Directory (a service-principal /
 * client-secret credential) and to address one Azure <em>subscription</em>. Every Key Vault in that
 * subscription (optionally narrowed by the filters) is discovered and managed by this one connector.
 * The object is populated by the TLM SDK from the values entered against the connector in TLM,
 * which map to the fields declared in {@code configuration.json}.
 * <ul>
 *   <li><b>tenantId</b>: Azure AD tenant (directory) ID.</li>
 *   <li><b>clientId</b>: Application (client) ID of the app registration / service principal.</li>
 *   <li><b>clientSecret</b>: Client secret for that app. In <em>Direct input</em> mode TLM stores it
 *       encrypted and hands it over base64-encoded; in <em>Secrets manager</em> mode the operator
 *       enters a PAM vault reference and TLM injects the resolved secret into this same field.</li>
 *   <li><b>subscriptionId</b>: the subscription whose vaults are managed (connector unique key).</li>
 *   <li><b>resourceGroups</b>, <b>vaultNamePattern</b>, <b>vaultTagFilter</b>: optional discovery
 *       filters applied to the ARM vault listing.</li>
 * </ul>
 * <b>Important:</b> Any field added, removed, or renamed here must also be reflected in
 * {@code configuration.json} so the TLM UI maps them correctly.
 */
package com.example.automation.extended.configuration;

import com.fasterxml.jackson.annotation.JsonAlias;
import com.fasterxml.jackson.annotation.JsonIgnoreProperties;

import lombok.Data;

@Data
@JsonIgnoreProperties(ignoreUnknown = true)
public class MyPluginConfiguration {

    /** {@code authentication_method} value for a secret typed directly into TLM. */
    public static final String AUTH_DIRECT = "Self authentication";

    /** {@code authentication_method} value for a secret resolved via a Secrets Manager (PAM) connector. */
    public static final String AUTH_SECRETS_MANAGER = "Self authentication secrets manager";

    /** The Azure AD tenant (directory) ID. */
    private String tenantId;

    /** The application (client) ID of the service principal. */
    private String clientId;

    /**
     * The client secret for the service principal. Direct-input mode: base64-encoded by TLM.
     * Secrets-manager mode: the resolved secret injected by the PAM connector at runtime.
     */
    private String clientSecret;

    /** The Azure subscription ID (GUID) whose Key Vaults this connector manages. */
    private String subscriptionId;

    /**
     * Optional comma-separated resource-group names. When set, only vaults in those resource groups
     * are discovered (and the principal only needs Reader on those groups, not the subscription).
     */
    private String resourceGroups;

    /** Optional case-insensitive regular expression a vault name must match to be discovered. */
    private String vaultNamePattern;

    /** Optional {@code key=value} tag a vault must carry to be discovered ({@code key} alone = present). */
    private String vaultTagFilter;

    /** How the client secret is supplied; see {@link #AUTH_DIRECT} / {@link #AUTH_SECRETS_MANAGER}. */
    @JsonAlias({"authentication_method", "authenticationMethod"})
    private String authenticationMethod;

    /** ID of the Secrets Manager (PAM) connector selected in TLM; diagnostics only. */
    @JsonAlias({"pam_connector_id", "pamConnectorId"})
    private String pamConnectorId;

    /** When {@code true}, discovery omits certificates whose active version has already expired. */
    private Boolean excludeExpiredCertificates;

    /** When {@code true}, discovery omits certificates that are disabled in the vault. */
    private Boolean excludeDisabledCertificates;

    /** True when the connector is configured to resolve the secret through a PAM connector. */
    public boolean isSecretsManagerAuth() {
        return AUTH_SECRETS_MANAGER.equalsIgnoreCase(authenticationMethod);
    }
}
