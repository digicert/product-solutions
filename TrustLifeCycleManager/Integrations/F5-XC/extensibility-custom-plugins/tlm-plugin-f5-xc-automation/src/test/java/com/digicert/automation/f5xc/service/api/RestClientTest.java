package com.digicert.automation.f5xc.service.api;

import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertThrows;

class RestClientTest {

    // ── Base URL derivation ─────────────────────────────────────────────────

    @Test
    @DisplayName("buildBaseUrl derives the console URL from a tenant short name")
    void buildBaseUrl_fromTenantShortName() {
        assertEquals("https://digicert.console.ves.volterra.io", RestClient.buildBaseUrl("digicert"));
    }

    @Test
    @DisplayName("buildBaseUrl accepts a full https URL verbatim")
    void buildBaseUrl_fromFullUrl() {
        assertEquals("https://digicert.console.ves.volterra.io",
                RestClient.buildBaseUrl("https://digicert.console.ves.volterra.io"));
    }

    @Test
    @DisplayName("buildBaseUrl trims a trailing slash from a full URL")
    void buildBaseUrl_trimsTrailingSlash() {
        assertEquals("https://custom.example.com",
                RestClient.buildBaseUrl("https://custom.example.com/"));
    }

    @Test
    @DisplayName("buildBaseUrl rejects a blank tenant")
    void buildBaseUrl_rejectsBlank() {
        assertThrows(IllegalArgumentException.class, () -> RestClient.buildBaseUrl("  "));
    }
}
