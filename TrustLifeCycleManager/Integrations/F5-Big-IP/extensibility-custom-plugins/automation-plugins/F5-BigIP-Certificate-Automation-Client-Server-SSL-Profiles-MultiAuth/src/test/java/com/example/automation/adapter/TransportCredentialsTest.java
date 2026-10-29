package com.example.automation.adapter;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertTrue;

import java.util.Base64;

import com.example.automation.extended.configuration.AuthMode;
import com.example.automation.extended.configuration.MyPluginConfiguration;

import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;

class TransportCredentialsTest {

    private static String b64(String value) {
        return Base64.getEncoder().encodeToString(value.getBytes());
    }

    private static MyPluginConfiguration baseConfig() {
        final var config = new MyPluginConfiguration();
        config.setManagementIp("10.0.0.1");
        config.setManagementPort("443");
        config.setUserName("admin");
        config.setPassword(b64("admin-secret"));
        return config;
    }

    // ── SHARED ────────────────────────────────────────────────────────────────

    @Test
    @DisplayName("SHARED: one decoded credential for REST and SSH, SSH fields ignored")
    void sharedMode() {
        final var config = baseConfig();
        config.setAuthMode("shared");
        config.setSshUserName("root");
        config.setSshPassword(b64("root-secret"));

        final var creds = TransportCredentials.resolve(config);

        assertTrue(creds.isValid());
        assertEquals(AuthMode.SHARED, creds.getAuthMode());
        assertEquals("admin", creds.getSsh().getUsername());
        assertEquals("admin-secret", creds.getSsh().getPassword());
        assertEquals(22, creds.getSsh().getSshPort());
        assertTrue(creds.rest().isPresent());
        assertEquals("admin", creds.getRest().getUsername());
        assertEquals("admin-secret", creds.getRest().getPassword());
        assertEquals("443", creds.getRest().getPort());
    }

    @Test
    @DisplayName("blank authMode behaves as SHARED (legacy connectors)")
    void blankModeIsShared() {
        final var creds = TransportCredentials.resolve(baseConfig());
        assertEquals(AuthMode.SHARED, creds.getAuthMode());
        assertTrue(creds.isValid());
    }

    // ── SEPARATE ──────────────────────────────────────────────────────────────

    @Test
    @DisplayName("SEPARATE: primary credential to REST, SSH credential to SSH, custom SSH port")
    void separateMode() {
        final var config = baseConfig();
        config.setAuthMode("separate");
        config.setSshUserName("root");
        config.setSshPassword(b64("root-secret"));
        config.setSshPort("2222");

        final var creds = TransportCredentials.resolve(config);

        assertTrue(creds.isValid());
        assertEquals("root", creds.getSsh().getUsername());
        assertEquals("root-secret", creds.getSsh().getPassword());
        assertEquals(2222, creds.getSsh().getSshPort());
        assertEquals("admin", creds.getRest().getUsername());
        assertEquals("admin-secret", creds.getRest().getPassword());
    }

    @Test
    @DisplayName("SEPARATE without SSH username and password collects two validation errors instead of throwing")
    void separateModeMissingSshCredentials() {
        final var config = baseConfig();
        config.setAuthMode("separate");

        final var creds = TransportCredentials.resolve(config);

        assertFalse(creds.isValid());
        assertEquals(2, creds.getValidationErrors().size());
        assertTrue(creds.getValidationErrors().get(0).contains("SSH username"));
        assertTrue(creds.getValidationErrors().get(1).contains("SSH password"));
    }

    @Test
    @DisplayName("SEPARATE with only the SSH username missing reports exactly that field")
    void separateModeMissingUsernameOnly() {
        final var config = baseConfig();
        config.setAuthMode("separate");
        config.setSshPassword(b64("root-secret"));

        final var creds = TransportCredentials.resolve(config);

        assertEquals(1, creds.getValidationErrors().size());
        assertTrue(creds.getValidationErrors().get(0).contains("SSH username"));
    }

    // ── SSH_ONLY ──────────────────────────────────────────────────────────────

    @Test
    @DisplayName("SSH_ONLY: no REST adapter config, primary credential used for SSH when SSH fields are blank")
    void sshOnlyFallsBackToPrimary() {
        final var config = baseConfig();
        config.setAuthMode("ssh_only");

        final var creds = TransportCredentials.resolve(config);

        assertTrue(creds.isValid());
        assertTrue(creds.rest().isEmpty());
        assertNull(creds.getRest());
        assertEquals("admin", creds.getSsh().getUsername());
        assertEquals("admin-secret", creds.getSsh().getPassword());
    }

    @Test
    @DisplayName("SSH_ONLY: SSH credential wins when both SSH fields are set")
    void sshOnlyPrefersSshCredential() {
        final var config = baseConfig();
        config.setAuthMode("ssh_only");
        config.setSshUserName("root");
        config.setSshPassword(b64("root-secret"));

        final var creds = TransportCredentials.resolve(config);

        assertEquals("root", creds.getSsh().getUsername());
        assertEquals("root-secret", creds.getSsh().getPassword());
        assertTrue(creds.rest().isEmpty());
    }

    // ── Common validation ─────────────────────────────────────────────────────

    @Test
    @DisplayName("missing management IP is a configuration error in every mode")
    void missingManagementIp() {
        final var config = baseConfig();
        config.setManagementIp(" ");

        final var creds = TransportCredentials.resolve(config);

        assertFalse(creds.isValid());
        assertTrue(creds.getValidationErrors().get(0).contains("Management IP"));
    }

    // ── describe ──────────────────────────────────────────────────────────────

    @Test
    @DisplayName("describe() names mode, credential source and identities but never a password")
    void describeHasNoSecrets() {
        final var config = baseConfig();
        config.setAuthMode("separate");
        config.setSshUserName("root");
        config.setSshPassword(b64("root-secret"));
        config.setAuthentication("from secrets manager");

        final var description = TransportCredentials.resolve(config).describe();

        assertTrue(description.contains("mode=SEPARATE"));
        assertTrue(description.contains("credentials=secrets-manager"));
        assertTrue(description.contains("ssh=root@10.0.0.1:22"));
        assertTrue(description.contains("rest=admin@10.0.0.1:443"));
        assertFalse(description.contains("admin-secret"));
        assertFalse(description.contains("root-secret"));
        assertFalse(description.contains(b64("admin-secret")));
    }

    @Test
    @DisplayName("describe() reports rest=disabled in SSH_ONLY mode")
    void describeSshOnly() {
        final var config = baseConfig();
        config.setAuthMode("ssh_only");
        assertTrue(TransportCredentials.resolve(config).describe().contains("rest=disabled"));
    }

    // ── decodePassword ────────────────────────────────────────────────────────

    @Test
    @DisplayName("decodePassword decodes base64 and falls back to the raw value for plain text")
    void decodePassword() {
        assertEquals("admin-secret", TransportCredentials.decodePassword(b64("admin-secret")));
        assertEquals("not base64!", TransportCredentials.decodePassword("not base64!"));
        assertNull(TransportCredentials.decodePassword(null));
        assertEquals("", TransportCredentials.decodePassword(""));
    }
}
