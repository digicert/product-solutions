
/**
 * Configuration class for the DigiCert TLM Automation Plugin (Azure Key Vault).
 * <p>
 * This class holds the parameters required to authenticate with Azure Active Directory (a
 * service-principal / client-secret credential) and to address a single Azure Key Vault. It is
 * populated by the TLM SDK from the values entered against the connector in TLM, which map to the
 * fields declared in {@code configuration.json}.
 * <ul>
 *   <li><b>tenantId</b>: Azure AD tenant (directory) ID.</li>
 *   <li><b>clientId</b>: Application (client) ID of the app registration / service principal.</li>
 *   <li><b>clientSecret</b>: Client secret for that app. In <em>Direct input</em> mode TLM stores it
 *       encrypted and hands it over base64-encoded; in <em>Secrets manager</em> mode the operator
 *       enters a PAM vault reference and TLM injects the resolved secret into this same field at
 *       runtime.</li>
 *   <li><b>keyVaultUrl</b>: Vault URL, e.g. {@code https://myvault.vault.azure.net/}.</li>
 *   <li><b>authenticationMethod</b> / <b>pamConnectorId</b>: the authentication mode selector and
 *       the chosen Secrets Manager (PAM) connector. Both are consumed by TLM to drive the UI and
 *       the secret-resolution step; the plugin reads them only for diagnostics.</li>
 * </ul>
 * <b>Important:</b> Any field added, removed, or renamed here must also be reflected in
 * {@code configuration.json} (the {@code config_settings} / {@code core_settings} sections) so the
 * TLM UI maps them correctly.
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
     * Secrets-manager mode: the resolved secret injected by the PAM connector at runtime (the
     * vault <em>reference</em> the operator typed never reaches the plugin).
     */
    private String clientSecret;

    /** The Azure Key Vault URL, e.g. {@code https://myvault.vault.azure.net/}. */
    private String keyVaultUrl;

    /**
     * How the client secret is supplied — one of {@link #AUTH_DIRECT} or
     * {@link #AUTH_SECRETS_MANAGER}. Null/absent means direct input (the default in
     * {@code configuration.json}). Used only for logging and clearer error messages.
     */
    @JsonAlias({"authentication_method", "authenticationMethod"})
    private String authenticationMethod;

    /**
     * ID of the Secrets Manager (PAM) connector selected in TLM when
     * {@link #AUTH_SECRETS_MANAGER} is in use; null otherwise. Diagnostics only — the plugin never
     * talks to the vault itself.
     */
    @JsonAlias({"pam_connector_id", "pamConnectorId"})
    private String pamConnectorId;

    /**
     * When {@code true}, discovery omits certificates whose active version has already expired.
     * Null/absent means false (show all). Backed by a checkbox in {@code configuration.json}, so it
     * arrives as a JSON boolean. Note TLM also offers a native "Exclude expired certificates" toggle
     * on the certificate-import screen; this plugin-side flag additionally trims the automation
     * discovery inventory.
     */
    private Boolean excludeExpiredCertificates;

    /**
     * When {@code true}, discovery omits certificates that are disabled in the vault. Null/absent
     * means false (show all). TLM has no concept of Azure's enabled/disabled state, so this filter
     * can only be applied here in the plugin.
     */
    private Boolean excludeDisabledCertificates;

    /** True when the connector is configured to resolve the secret through a PAM connector. */
    public boolean isSecretsManagerAuth() {
        return AUTH_SECRETS_MANAGER.equalsIgnoreCase(authenticationMethod);
    }
}
