/**
 * Configuration class for the DigiCert TLM F5 Distributed Cloud (F5-XC) Automation Plugin.
 * <p>
 * Holds the connection parameters required to authenticate against the F5-XC REST API.
 * Authentication uses an <b>API Token</b> sent on every request as the
 * {@code Authorization: APIToken <token>} header.
 * <ul>
 *   <li><b>tenant</b>: F5-XC tenant short name. The API base URL is derived as
 *       {@code https://<tenant>.console.ves.volterra.io}.</li>
 *   <li><b>namespace</b>: F5-XC namespace that owns the certificate objects
 *       (e.g. {@code default}).</li>
 *   <li><b>apiToken</b>: F5-XC API Token (sensitive credential). In <em>Direct input</em> mode
 *       the operator types it into TLM; in <em>Secrets manager</em> mode the operator enters a
 *       PAM vault reference and TLM injects the resolved token into this same field at runtime.</li>
 *   <li><b>authenticationMethod</b> / <b>pamConnectorId</b>: the authentication mode selector and
 *       the chosen Secrets Manager (PAM) connector. Both are consumed by TLM to drive the UI and
 *       the secret-resolution step; the plugin reads them only for diagnostics.</li>
 * </ul>
 * <b>Important:</b> Any change to the fields here (add/remove/rename) must be mirrored in
 * {@code configuration.json} ({@code config_settings} and {@code credential_sets}).
 *
 * @author michael.rudloff
 */
package com.digicert.automation.extended.configuration;

import com.fasterxml.jackson.annotation.JsonAlias;
import com.fasterxml.jackson.annotation.JsonIgnoreProperties;

import lombok.Data;

/**
 * @author michael.rudloff
 */
@Data
@JsonIgnoreProperties(ignoreUnknown = true)
public class F5XCPluginConfiguration {

    /** {@code authentication_method} value for a token typed directly into TLM. */
    public static final String AUTH_DIRECT = "Self authentication";

    /** {@code authentication_method} value for a token resolved via a Secrets Manager (PAM) connector. */
    public static final String AUTH_SECRETS_MANAGER = "Self authentication secrets manager";

    /** F5-XC tenant short name (base URL = https://&lt;tenant&gt;.console.ves.volterra.io). */
    private String tenant;

    /** F5-XC namespace that owns the certificate objects (e.g. {@code default}). */
    private String namespace;

    /**
     * F5-XC API Token, sent as {@code Authorization: APIToken <token>}. Direct-input mode: the
     * value typed into TLM. Secrets-manager mode: the resolved token injected by the PAM connector
     * at runtime (the vault <em>reference</em> the operator typed never reaches the plugin).
     */
    private String apiToken;

    /**
     * How the API token is supplied — one of {@link #AUTH_DIRECT} or
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

    /** True when the connector is configured to resolve the token through a PAM connector. */
    public boolean isSecretsManagerAuth() {
        return AUTH_SECRETS_MANAGER.equalsIgnoreCase(authenticationMethod);
    }
}
