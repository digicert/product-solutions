
/**
 * Configuration class for the DigiCert TLM Automation Plugin.
 * <p>
 * This class holds the configuration parameters required to connect and authenticate
 * with the managed system. It is typically populated from user input or configuration files.
 * <ul>
 *   <li><b>userName</b>: The username for authentication.</li>
 *   <li><b>password</b>: The password for authentication.</li>
 *   <li><b>managementIp</b>: The IP address of the management interface.</li>
 *   <li><b>managementPort</b>: The port number of the management interface.</li>
 * </ul>
 * <b>Usage:</b> This class is used by the plugin to retrieve connection details and credentials.<br>
 * <b>Customization:</b> Users can customize this class to add, remove, or modify configuration parameters as needed for their specific plugin requirements.<br>
 * <b>Important:</b> Any changes made to this class (such as adding, removing, or renaming fields) must also be reflected in the <code>configuration.json</code> file, specifically in the <code>config_settings</code> and <code>core_settings</code> sections, to ensure proper mapping and plugin functionality.
 */
package com.example.automation.extended.configuration;

import com.fasterxml.jackson.annotation.JsonAlias;

import lombok.Data;

@Data
public class MyPluginConfiguration {

    /**
     * The username for authenticating with the managed system.
     */
    private String userName;

    /**
     * The password for authenticating with the managed system.
     */
    private String password;

    /**
     * The IP address of the management interface.
     */
    private String managementIp;

    /**
     * The port number of the management interface.
     */
    private String managementPort;

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
