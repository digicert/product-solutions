/**
 * Configuration class for the DigiCert TLM Automation Plugin.
 * <p>
 * This class holds the configuration parameters required to connect and authenticate
 * with the managed system. It is populated by TLM from the connector form described in
 * <code>configuration.json</code>.
 * <ul>
 *   <li><b>userName</b> / <b>password</b>: the primary credential. Used for REST and SSH in
 *       {@code SHARED} mode, for REST only in {@code SEPARATE} mode, for SSH in {@code SSH_ONLY} mode.</li>
 *   <li><b>authentication</b> / <b>pamConnectorId</b>: credentials source. "manual entry" (default) or
 *       "from secrets manager", in which case TLM resolves the vault references entered in the password
 *       fields through the selected PAM connector before the plugin runs.</li>
 *   <li><b>managementIp</b> / <b>managementPort</b>: management address and iControl REST port.</li>
 *   <li><b>authMode</b>: {@code shared} (default), {@code separate} or {@code ssh_only}. See {@link AuthMode}.</li>
 *   <li><b>sshUserName</b> / <b>sshPassword</b>: the SSH credential, required in {@code SEPARATE} mode.</li>
 *   <li><b>sshPort</b>: SSH port, defaults to 22.</li>
 *   <li><b>groupSyncEnabled</b>: run a config-sync to the sync-failover device group after CSR generation
 *       and certificate install. Off by default.</li>
 * </ul>
 * <b>Important:</b> Any changes made to this class (such as adding, removing, or renaming fields) must also be
 * reflected in the <code>configuration.json</code> file, specifically in the <code>config_settings</code> and
 * <code>credential_sets</code> sections, to ensure proper mapping and plugin functionality.
 */
package com.example.automation.extended.configuration;

import com.fasterxml.jackson.annotation.JsonAlias;

import lombok.Data;

@Data
public class MyPluginConfiguration {

    public static final int DEFAULT_SSH_PORT = 22;

    /** Connector value of the "Credentials source" radio group when a secrets manager is used. */
    public static final String SECRETS_MANAGER_SOURCE = "from secrets manager";

    /**
     * The primary username. REST identity in SHARED and SEPARATE modes, SSH identity in SHARED and SSH_ONLY modes.
     */
    @JsonAlias({"username", "user_name"})
    private String userName;

    /**
     * The primary password (arrives base64-encoded from TLM).
     */
    private String password;

    /**
     * The IP address of the management interface.
     */
    @JsonAlias({"management_ip"})
    private String managementIp;

    /**
     * The port number of the iControl REST management interface (443, or 8443 on single-NIC deployments).
     */
    @JsonAlias({"management_port"})
    private String managementPort;

    /**
     * "Credentials source" radio group: {@code manual entry} (default) or {@value #SECRETS_MANAGER_SOURCE}.
     * Informational for the plugin; TLM resolves vault references before the configuration reaches us.
     */
    private String authentication;

    /**
     * Secrets manager connector selected when {@link #authentication} is {@value #SECRETS_MANAGER_SOURCE}.
     */
    @JsonAlias({"pam_connector_id", "pamConnector"})
    private String pamConnectorId;

    /**
     * Authentication model: {@code shared}, {@code separate} or {@code ssh_only}. Null or blank (connectors
     * created with the single-credential plugin) means {@code shared}.
     */
    @JsonAlias({"auth_mode", "authenticationMode", "authentication_mode"})
    private String authMode;

    /**
     * SSH username. Required in SEPARATE mode. In SSH_ONLY mode it is honoured when both SSH fields are set,
     * otherwise the primary credential is used. Ignored in SHARED mode.
     */
    @JsonAlias({"ssh_user_name", "sshUsername", "ssh_username"})
    private String sshUserName;

    /**
     * SSH password (arrives base64-encoded from TLM). Same rules as {@link #sshUserName}.
     */
    @JsonAlias({"ssh_password"})
    private String sshPassword;

    /**
     * SSH port. Null, blank or non-numeric means {@value #DEFAULT_SSH_PORT}.
     */
    @JsonAlias({"ssh_port"})
    private String sshPort;

    /**
     * "Enable HA group sync" checkbox. TLM delivers checkbox values as strings ({@code "true"} / {@code "false"}).
     * Null or blank means disabled.
     */
    @JsonAlias({"group_sync_enabled", "groupSync"})
    private String groupSyncEnabled;

    /**
     * Whether an install also repoints the server-ssl profiles on the virtual server that carry the
     * certificate being replaced (a VIP that re-encrypts to its pool members with the same certificate).
     * TLM delivers select values as strings, so this is {@code "true"} / {@code "false"}.
     * Null or blank (connectors created before the field existed) means enabled.
     */
    @JsonAlias({"update_server_ssl_profile", "updateServerSsl"})
    private String updateServerSslProfile;

    /**
     * How the client-ssl profile is handled on install: {@code "update"} modifies the existing profile's
     * cert-key-chain in place, {@code "create"} copies it to a new profile named after the new key, binds
     * the copy and unbinds the original (the legacy behaviour). TLM has no UI for the per-request
     * {@code updateSameSslProfile} flag on custom plugins, so this connector setting is authoritative.
     * Null or blank (connectors created before the field existed) means {@code "update"}.
     */
    @JsonAlias({"client_ssl_profile_mode", "clientSslMode"})
    private String clientSslProfileMode;

    /**
     * @return the parsed authentication mode, defaulting to {@link AuthMode#SHARED}.
     */
    public AuthMode getResolvedAuthMode() {
        return AuthMode.from(authMode);
    }

    /**
     * @return the SSH port to connect to, defaulting to {@value #DEFAULT_SSH_PORT}.
     */
    public int getResolvedSshPort() {
        if (sshPort == null || sshPort.isBlank()) {
            return DEFAULT_SSH_PORT;
        }
        try {
            final var parsed = Integer.parseInt(sshPort.trim());
            return parsed > 0 && parsed <= 65535 ? parsed : DEFAULT_SSH_PORT;
        } catch (NumberFormatException e) {
            return DEFAULT_SSH_PORT;
        }
    }

    /**
     * @return {@code true} when both SSH credential fields are populated.
     */
    public boolean hasSshCredentials() {
        return sshUserName != null && !sshUserName.isBlank()
                && sshPassword != null && !sshPassword.isBlank();
    }

    /**
     * @return {@code true} when the connector takes its passwords from a secrets manager connector.
     */
    public boolean isSecretsManagerSource() {
        return authentication != null && SECRETS_MANAGER_SOURCE.equalsIgnoreCase(authentication.trim());
    }

    /**
     * @return {@code true} when a config-sync must run after CSR generation and certificate install.
     */
    public boolean isGroupSyncEnabled() {
        return parseFlag(groupSyncEnabled, false);
    }

    /**
     * @return {@code true} to update the bound client-ssl profile in place, {@code false} to create a new one.
     */
    public boolean isUpdateSameClientSslProfile() {
        if (clientSslProfileMode == null || clientSslProfileMode.isBlank()) {
            return true;
        }
        final var value = clientSslProfileMode.trim();
        return !(value.equalsIgnoreCase("create") || value.equalsIgnoreCase("new")
                || value.equalsIgnoreCase("false"));
    }

    /**
     * @return {@code true} unless the connector explicitly disabled server-ssl profile updates.
     */
    public boolean isUpdateServerSslProfileEnabled() {
        return parseFlag(updateServerSslProfile, true);
    }

    private static boolean parseFlag(String raw, boolean defaultValue) {
        if (raw == null || raw.isBlank()) {
            return defaultValue;
        }
        final var value = raw.trim();
        return value.equalsIgnoreCase("true") || value.equalsIgnoreCase("yes") || value.equals("1");
    }
}
