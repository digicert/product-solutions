package com.example.automation.extended.configuration;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;

import com.fasterxml.jackson.databind.ObjectMapper;

import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;

class MyPluginConfigurationTest {

    private static final ObjectMapper MAPPER = new ObjectMapper();

    // ── SSH port ──────────────────────────────────────────────────────────────

    @Test
    @DisplayName("blank SSH port defaults to 22")
    void sshPortBlankDefaults() {
        final var config = new MyPluginConfiguration();
        assertEquals(22, config.getResolvedSshPort());
        config.setSshPort("   ");
        assertEquals(22, config.getResolvedSshPort());
    }

    @Test
    @DisplayName("non-numeric or out-of-range SSH port defaults to 22")
    void sshPortInvalidDefaults() {
        final var config = new MyPluginConfiguration();
        config.setSshPort("twenty-two");
        assertEquals(22, config.getResolvedSshPort());
        config.setSshPort("0");
        assertEquals(22, config.getResolvedSshPort());
        config.setSshPort("70000");
        assertEquals(22, config.getResolvedSshPort());
    }

    @Test
    @DisplayName("valid SSH port is used, surrounding whitespace ignored")
    void sshPortValid() {
        final var config = new MyPluginConfiguration();
        config.setSshPort(" 2222 ");
        assertEquals(2222, config.getResolvedSshPort());
    }

    // ── SSH credentials ───────────────────────────────────────────────────────

    @Test
    @DisplayName("hasSshCredentials requires both username and password")
    void hasSshCredentials() {
        final var config = new MyPluginConfiguration();
        assertFalse(config.hasSshCredentials());
        config.setSshUserName("root");
        assertFalse(config.hasSshCredentials());
        config.setSshPassword("c2VjcmV0");
        assertTrue(config.hasSshCredentials());
        config.setSshUserName(" ");
        assertFalse(config.hasSshCredentials());
    }

    // ── Client-ssl profile mode ───────────────────────────────────────────────

    @Test
    @DisplayName("client-ssl profile mode blank means update in place")
    void clientSslBlankIsUpdate() {
        final var config = new MyPluginConfiguration();
        assertTrue(config.isUpdateSameClientSslProfile());
        config.setClientSslProfileMode("update");
        assertTrue(config.isUpdateSameClientSslProfile());
    }

    @Test
    @DisplayName("client-ssl profile mode create/new/false means create a new profile")
    void clientSslCreate() {
        final var config = new MyPluginConfiguration();
        for (String value : new String[] {"create", "New", "false", " CREATE "}) {
            config.setClientSslProfileMode(value);
            assertFalse(config.isUpdateSameClientSslProfile(), value);
        }
    }

    // ── Server-ssl flag ───────────────────────────────────────────────────────

    @Test
    @DisplayName("server-ssl update blank means enabled (connectors created before the field existed)")
    void serverSslBlankIsEnabled() {
        final var config = new MyPluginConfiguration();
        assertTrue(config.isUpdateServerSslProfileEnabled());
    }

    @Test
    @DisplayName("server-ssl update honours true/yes/1 and false")
    void serverSslValues() {
        final var config = new MyPluginConfiguration();
        for (String value : new String[] {"true", "Yes", "1"}) {
            config.setUpdateServerSslProfile(value);
            assertTrue(config.isUpdateServerSslProfileEnabled(), value);
        }
        for (String value : new String[] {"false", "no", "0", "anything"}) {
            config.setUpdateServerSslProfile(value);
            assertFalse(config.isUpdateServerSslProfileEnabled(), value);
        }
    }

    // ── HA group sync ─────────────────────────────────────────────────────────

    @Test
    @DisplayName("HA group sync blank means disabled")
    void groupSyncBlankIsDisabled() {
        final var config = new MyPluginConfiguration();
        assertFalse(config.isGroupSyncEnabled());
        config.setGroupSyncEnabled("false");
        assertFalse(config.isGroupSyncEnabled());
    }

    @Test
    @DisplayName("HA group sync enabled by true/yes/1 (TLM sends checkbox values as strings)")
    void groupSyncEnabled() {
        final var config = new MyPluginConfiguration();
        for (String value : new String[] {"true", "TRUE", "yes", "1"}) {
            config.setGroupSyncEnabled(value);
            assertTrue(config.isGroupSyncEnabled(), value);
        }
    }

    // ── Credentials source ────────────────────────────────────────────────────

    @Test
    @DisplayName("secrets manager source detected from the radio-group value, case-insensitive")
    void secretsManagerSource() {
        final var config = new MyPluginConfiguration();
        assertFalse(config.isSecretsManagerSource());
        config.setAuthentication("manual entry");
        assertFalse(config.isSecretsManagerSource());
        config.setAuthentication("From Secrets Manager");
        assertTrue(config.isSecretsManagerSource());
    }

    // ── JSON mapping from the connector form ──────────────────────────────────

    @Test
    @DisplayName("connector JSON with camelCase and snake_case keys maps onto the configuration")
    void jsonAliases() throws Exception {
        final var json = """
                {
                  "userName": "admin",
                  "password": "cGFzcw==",
                  "managementIp": "10.0.0.1",
                  "managementPort": "8443",
                  "authentication": "from secrets manager",
                  "pam_connector_id": "pam-123",
                  "auth_mode": "separate",
                  "ssh_user_name": "root",
                  "ssh_password": "cm9vdA==",
                  "ssh_port": "2222",
                  "group_sync_enabled": "true",
                  "update_server_ssl_profile": "false",
                  "client_ssl_profile_mode": "create"
                }
                """;
        final var config = MAPPER.readValue(json, MyPluginConfiguration.class);
        assertEquals("admin", config.getUserName());
        assertEquals("pam-123", config.getPamConnectorId());
        assertEquals(AuthMode.SEPARATE, config.getResolvedAuthMode());
        assertEquals("root", config.getSshUserName());
        assertEquals(2222, config.getResolvedSshPort());
        assertTrue(config.isGroupSyncEnabled());
        assertFalse(config.isUpdateServerSslProfileEnabled());
        assertFalse(config.isUpdateSameClientSslProfile());
        assertTrue(config.isSecretsManagerSource());
    }
}
