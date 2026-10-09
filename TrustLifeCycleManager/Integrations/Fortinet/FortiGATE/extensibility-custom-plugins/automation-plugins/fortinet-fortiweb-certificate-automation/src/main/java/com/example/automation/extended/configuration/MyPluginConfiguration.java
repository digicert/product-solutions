
/**
 * Configuration class for the DigiCert TLM Automation Plugin (Fortinet FortiWeb).
 * <p>
 * This class holds the parameters required to reach one FortiWeb appliance's REST API and to
 * authenticate against it. It is populated by the TLM SDK from the values entered against the
 * connector in TLM, which map to the fields declared in {@code configuration.json}.
 * <ul>
 *   <li><b>host</b>: FortiWeb management FQDN or IP (scheme / port / path are tolerated and stripped).</li>
 *   <li><b>port</b>: REST API port; blank means 443.</li>
 *   <li><b>username</b> ({@code config_attributes.userName} in the UI): FortiWeb administrator used for the API.</li>
 *   <li><b>password</b>: that administrator's password. In <em>Direct input</em> mode TLM stores it
 *       encrypted and hands it over base64-encoded; in <em>Secrets manager</em> mode the operator
 *       enters a PAM vault reference and TLM injects the resolved secret into this same field at
 *       runtime.</li>
 *   <li><b>vdom</b>: FortiWeb ADOM (sent as {@code vdom} in the API token); blank means {@code root}.</li>
 *   <li><b>sshPort</b>: SSH port for the read-only CLI fetch of certificate bodies; blank means 22, {@code 0} disables it.</li>
 *   <li><b>keepReplacedCertificate</b>: leave the superseded certificate on the appliance instead
 *       of deleting it after every reference has been repointed.</li>
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

    /** {@code authentication_method} value for a password typed directly into TLM. */
    public static final String AUTH_DIRECT = "Self authentication";

    /** {@code authentication_method} value for a password resolved via a Secrets Manager (PAM) connector. */
    public static final String AUTH_SECRETS_MANAGER = "Self authentication secrets manager";

    /** FortiWeb management host (FQDN or IP). */
    private String host;

    /** FortiWeb REST API port as a string (TLM inputs are strings); blank → 443. */
    private String port;

    /**
     * FortiWeb administrator account used for the REST API. Declared as
     * {@code config_attributes.userName} in {@code configuration.json}: TLM only persists / delivers
     * the camelCase spelling (a field named {@code username} arrives as null), which is why every
     * DigiCert automation plugin uses {@code userName}. The aliases accept either spelling.
     */
    @JsonAlias({"userName", "username", "user_name"})
    private String username;

    /**
     * Password of that account. Direct-input mode: base64-encoded by TLM. Secrets-manager mode: the
     * resolved secret injected by the PAM connector at runtime (the vault <em>reference</em> the
     * operator typed never reaches the plugin).
     */
    private String password;

    /** FortiWeb ADOM name; blank means {@code root}. */
    private String vdom;

    /**
     * SSH port of the FortiWeb management interface, used with the same username/password for one
     * read-only CLI command ({@code show system certificate local}) that returns the certificate
     * bodies the REST API withholds. Blank/absent means 22; {@code 0} disables SSH (discovery then
     * shows metadata only).
     */
    private String sshPort;

    /**
     * When {@code true}, the replaced certificate is left on FortiWeb after rotation. Null/absent
     * means false (delete it once unreferenced). Backed by a checkbox in {@code configuration.json}.
     */
    private Boolean keepReplacedCertificate;

    /**
     * How the password is supplied — one of {@link #AUTH_DIRECT} or {@link #AUTH_SECRETS_MANAGER}.
     * Null/absent means direct input (the default in {@code configuration.json}). Used only for
     * logging and clearer error messages.
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

    /** True when the connector is configured to resolve the password through a PAM connector. */
    public boolean isSecretsManagerAuth() {
        return AUTH_SECRETS_MANAGER.equalsIgnoreCase(authenticationMethod);
    }
}
