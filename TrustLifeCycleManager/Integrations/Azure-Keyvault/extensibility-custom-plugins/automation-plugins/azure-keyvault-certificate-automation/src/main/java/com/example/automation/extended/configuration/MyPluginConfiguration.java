
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
 *   <li><b>clientSecret</b>: Client secret for that app (passed base64-encoded by TLM).</li>
 *   <li><b>keyVaultUrl</b>: Vault URL, e.g. {@code https://myvault.vault.azure.net/}.</li>
 * </ul>
 * <b>Important:</b> Any field added, removed, or renamed here must also be reflected in
 * {@code configuration.json} (the {@code config_settings} / {@code core_settings} sections) so the
 * TLM UI maps them correctly.
 */
package com.example.automation.extended.configuration;

import lombok.Data;

@Data
public class MyPluginConfiguration {

    /** The Azure AD tenant (directory) ID. */
    private String tenantId;

    /** The application (client) ID of the service principal. */
    private String clientId;

    /** The client secret for the service principal (passed base64-encoded by TLM). */
    private String clientSecret;

    /** The Azure Key Vault URL, e.g. {@code https://myvault.vault.azure.net/}. */
    private String keyVaultUrl;

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
}
