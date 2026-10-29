package com.example.automation.adapter;

import static com.github.tomakehurst.wiremock.client.WireMock.aResponse;
import static com.github.tomakehurst.wiremock.client.WireMock.equalTo;
import static com.github.tomakehurst.wiremock.client.WireMock.get;
import static com.github.tomakehurst.wiremock.client.WireMock.getRequestedFor;
import static com.github.tomakehurst.wiremock.client.WireMock.urlEqualTo;
import static com.github.tomakehurst.wiremock.core.WireMockConfiguration.wireMockConfig;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertTrue;

import java.util.Base64;

import com.example.automation.model.ErrorCode;
import com.github.tomakehurst.wiremock.junit5.WireMockExtension;

import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Tag;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.RegisterExtension;

/**
 * Drives the real REST adapter against WireMock over HTTPS. The adapter trusts any certificate, and
 * the runner's hostname-verification override is applied here too, so WireMock's self-signed
 * certificate is accepted exactly as a BIG-IP's would be.
 */
@Tag("integration")
class F5iControlRestAdapterIT {

    @RegisterExtension
    static WireMockExtension wm = WireMockExtension.newInstance()
            .options(wireMockConfig().dynamicPort().dynamicHttpsPort())
            .build();

    @BeforeAll
    static void disableHostnameVerification() {
        // Same flag F5AutomationPluginRunner sets before any HttpClient is built.
        System.setProperty("jdk.internal.httpclient.disableHostnameVerification", "true");
    }

    private F5iControlRestAdapter adapter(String username, String password) {
        return new F5iControlRestAdapter(AdapterConfig.builder()
                .host("localhost")
                .port(String.valueOf(wm.getHttpsPort()))
                .username(username)
                .password(password)
                .build());
    }

    @Test
    @DisplayName("200 from /mgmt/tm/sys/version with the basic-auth header is an active connection")
    void success() {
        wm.stubFor(get(urlEqualTo("/mgmt/tm/sys/version"))
                .willReturn(aResponse().withStatus(200)
                        .withHeader("Content-Type", "application/json")
                        .withBody("{\"kind\":\"tm:sys:version:versionstats\"}")));

        final var result = adapter("admin", "secret").testConnection();

        assertTrue(result.isSuccess());
        assertTrue(result.getValue().isActive());
        final var expectedAuth = "Basic " + Base64.getEncoder().encodeToString("admin:secret".getBytes());
        wm.verify(getRequestedFor(urlEqualTo("/mgmt/tm/sys/version"))
                .withHeader("Authorization", equalTo(expectedAuth))
                .withHeader("Accept", equalTo("application/json")));
    }

    @Test
    @DisplayName("401 maps to UNAUTHORIZED so the operator knows the REST identity is wrong")
    void unauthorized() {
        wm.stubFor(get(urlEqualTo("/mgmt/tm/sys/version"))
                .willReturn(aResponse().withStatus(401)
                        .withBody("{\"code\":401,\"message\":\"Authorization Required\"}")));

        final var result = adapter("admin", "wrong").testConnection();

        assertFalse(result.isSuccess());
        assertEquals(ErrorCode.UNAUTHORIZED.name(), result.getErrorCode());
    }

    @Test
    @DisplayName("500 maps to INTERNAL_ERROR")
    void serverError() {
        wm.stubFor(get(urlEqualTo("/mgmt/tm/sys/version"))
                .willReturn(aResponse().withStatus(500).withBody("boom")));

        final var result = adapter("admin", "secret").testConnection();

        assertFalse(result.isSuccess());
        assertEquals(ErrorCode.INTERNAL_ERROR.name(), result.getErrorCode());
    }

    @Test
    @DisplayName("unreachable port is a failure result, not an exception")
    void connectionRefused() {
        final var closedPort = String.valueOf(wm.getHttpsPort() + 1);
        final var adapter = new F5iControlRestAdapter(AdapterConfig.builder()
                .host("localhost").port(closedPort).username("admin").password("secret").build());

        final var result = adapter.testConnection();

        assertFalse(result.isSuccess());
        assertEquals(ErrorCode.INTERNAL_ERROR.name(), result.getErrorCode());
    }
}
