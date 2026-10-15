/**
 * Configuration class for the DigiCert TLM Automation Plugin.
 * <p>
 * This class holds the configuration parameters required to connect and authenticate
 * with the managed system. It is populated by TLM from the connector form described in
 * <code>configuration.json</code>.
 * <ul>
 *   <li><b>userName</b> / <b>password</b>: the primary credential. Used for REST and SSH in
 *       {@code SHARED} mode, for REST only in {@code SEPARATE} mode, for SSH in {@code SSH_ONLY} mode.</li>
 *   <li><b>managementIp</b> / <b>managementPort</b>: management address and iControl REST port.</li>
 *   <li><b>authMode</b>: {@code shared} (default), {@code separate} or {@code ssh_only}. See {@link AuthMode}.</li>
 *   <li><b>sshUserName</b> / <b>sshPassword</b>: the SSH credential, required in {@code SEPARATE} mode.</li>
 *   <li><b>sshPort</b>: SSH port, defaults to 22.</li>
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

    /**
     * The primary username. REST identity in SHARED and SEPARATE modes, SSH identity in SHARED and SSH_ONLY modes.
     */
    private String userName;

    /**
     * The primary password (arrives base64-encoded from TLM).
     */
    private String password;

    /**
     * The IP address of the management interface.
     */
    private String managementIp;

    /**
     * The port number of the iControl REST management interface (443, or 8443 on single-NIC deployments).
     */
    private String managementPort;

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
        if (updateServerSslProfile == null || updateServerSslProfile.isBlank()) {
            return true;
        }
        final var value = updateServerSslProfile.trim();
        return value.equalsIgnoreCase("true") || value.equalsIgnoreCase("yes") || value.equals("1");
    }
}
