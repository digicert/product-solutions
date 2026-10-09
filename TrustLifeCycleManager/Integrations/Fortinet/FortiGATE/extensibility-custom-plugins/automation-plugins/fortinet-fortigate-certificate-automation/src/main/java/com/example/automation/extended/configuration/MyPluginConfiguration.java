
/**
 * Configuration class for the DigiCert TLM Automation Plugin (Fortinet FortiGate).
 * <p>
 * This class holds the parameters required to reach one FortiGate's REST API and to authenticate
 * against it. It is populated by the TLM SDK from the values entered against the connector in TLM,
 * which map to the fields declared in {@code configuration.json}.
 * <ul>
 *   <li><b>host</b>: FortiGate management FQDN or IP (scheme / port / path are tolerated and stripped).</li>
 *   <li><b>port</b>: HTTPS administrative-access / REST API port; blank means 443.</li>
 *   <li><b>password</b>: the <em>REST API administrator token</em>. In <em>Direct input</em> mode
 *       TLM stores it encrypted and hands it over base64-encoded; in <em>Secrets manager</em> mode
 *       the operator enters a PAM vault reference and TLM injects the resolved secret into this
 *       same field at runtime. (The field keeps the name {@code password} because that is the field
 *       TLM's sensitive-credential and PAM handling is wired to.)</li>
 *   <li><b>vdom</b>: VDOM the connector works in; blank means {@code root}.</li>
 *   <li><b>certificateScope</b>: {@code global} (default) or {@code vdom} — where the managed
 *       certificates live.</li>
 *   <li><b>keepReplacedCertificate</b>: {@code keep} to leave the superseded certificate on the
 *       appliance instead of deleting it after every reference has been repointed.</li>
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

    /** {@code authentication_method} value for a token typed directly into TLM. */
    public static final String AUTH_DIRECT = "Self authentication";

    /** {@code authentication_method} value for a token resolved via a Secrets Manager (PAM) connector. */
    public static final String AUTH_SECRETS_MANAGER = "Self authentication secrets manager";

    /**
     * FortiGate management host (FQDN or IP). Declared as {@code config_attributes.management_ip}
     * in {@code configuration.json} (renamed from {@code host} on DigiCert engineering's advice,
     * 2026-09-23); connectors created under the old name still deliver {@code host}, so both are
     * accepted.
     */
    @JsonAlias({"management_ip", "managementIp", "host", "hostname"})
    private String host;

    /** FortiGate REST API port as a string (TLM inputs are strings); blank → 443. */
    private String port;

    /**
     * REST API administrator token. Direct-input mode: base64-encoded by TLM. Secrets-manager mode:
     * the resolved secret injected by the PAM connector at runtime (the vault <em>reference</em> the
     * operator typed never reaches the plugin).
     */
    @JsonAlias({"password", "apiToken", "api_token", "token"})
    private String password;

    /** VDOM name; blank means {@code root}. */
    private String vdom;

    /** {@code global} (default) or {@code vdom}. */
    @JsonAlias({"certificateScope", "certificate_scope", "scope"})
    private String certificateScope;

    /**
     * What to do with the replaced certificate after rotation. Backed by a required select in
     * {@code configuration.json} ({@code delete} / {@code keep}); older connectors may still deliver
     * the checkbox's boolean, so {@link #isKeepReplacedCertificate()} accepts both.
     */
    @JsonAlias({"keepReplacedCertificate", "keep_replaced_certificate", "replacedCertificate"})
    private String keepReplacedCertificate;

    /** True when the replaced certificate must be left on the appliance ({@code keep} / {@code true} / {@code yes}). */
    public boolean isKeepReplacedCertificate() {
        if (keepReplacedCertificate == null) {
            return false;
        }
        final var v = keepReplacedCertificate.trim().toLowerCase();
        return v.equals("keep") || v.equals("true") || v.equals("yes") || v.equals("on") || v.equals("1");
    }

    /**
     * How the token is supplied — one of {@link #AUTH_DIRECT} or {@link #AUTH_SECRETS_MANAGER}.
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

    /** True when the connector is configured to resolve the token through a PAM connector. */
    public boolean isSecretsManagerAuth() {
        return AUTH_SECRETS_MANAGER.equalsIgnoreCase(authenticationMethod);
    }
}
