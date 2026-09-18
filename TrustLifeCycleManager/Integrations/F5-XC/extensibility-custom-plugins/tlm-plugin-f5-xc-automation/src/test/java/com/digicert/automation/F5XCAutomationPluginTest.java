package com.digicert.automation;

import com.digicert.automation.extended.configuration.F5XCPluginConfiguration;
import com.fasterxml.jackson.databind.ObjectMapper;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertTrue;

class F5XCAutomationPluginTest {

    // ── API token check ─────────────────────────────────────────────────────

    @Test
    @DisplayName("checkApiToken accepts a non-blank token")
    void checkApiToken_acceptsToken() {
        F5XCPluginConfiguration cfg = new F5XCPluginConfiguration();
        cfg.setApiToken("abc123");
        assertNull(F5XCAutomationPlugin.checkApiToken(cfg));
    }

    @Test
    @DisplayName("checkApiToken reports an empty token in direct-input mode")
    void checkApiToken_directInputEmpty() {
        F5XCPluginConfiguration cfg = new F5XCPluginConfiguration();
        cfg.setApiToken("  ");
        String error = F5XCAutomationPlugin.checkApiToken(cfg);
        assertNotNull(error);
        assertTrue(error.contains("API token is empty"));
    }

    @Test
    @DisplayName("checkApiToken names the PAM connector in secrets-manager mode")
    void checkApiToken_secretsManagerEmpty() {
        F5XCPluginConfiguration cfg = new F5XCPluginConfiguration();
        cfg.setAuthenticationMethod(F5XCPluginConfiguration.AUTH_SECRETS_MANAGER);
        cfg.setPamConnectorId("pam-42");
        String error = F5XCAutomationPlugin.checkApiToken(cfg);
        assertNotNull(error);
        assertTrue(error.contains("Secrets Manager (PAM) connector 'pam-42'"));
    }

    // ── Configuration deserialization ───────────────────────────────────────

    @Test
    @DisplayName("configuration maps TLM snake_case PAM attributes and ignores unknown fields")
    void configuration_deserializesPamAttributes() throws Exception {
        String json = "{"
                + "\"tenant\":\"digicert\","
                + "\"namespace\":\"default\","
                + "\"apiToken\":\"tok\","
                + "\"authentication_method\":\"Self authentication secrets manager\","
                + "\"pam_connector_id\":\"pam-1\","
                + "\"someFutureField\":true"
                + "}";
        F5XCPluginConfiguration cfg = new ObjectMapper().readValue(json, F5XCPluginConfiguration.class);
        assertEquals("pam-1", cfg.getPamConnectorId());
        assertTrue(cfg.isSecretsManagerAuth());
    }

    @Test
    @DisplayName("configuration defaults to direct input when authentication_method is absent")
    void configuration_defaultsToDirectInput() throws Exception {
        String json = "{\"tenant\":\"digicert\",\"namespace\":\"default\",\"apiToken\":\"tok\"}";
        F5XCPluginConfiguration cfg = new ObjectMapper().readValue(json, F5XCPluginConfiguration.class);
        assertFalse(cfg.isSecretsManagerAuth());
        assertNull(cfg.getPamConnectorId());
    }
}
