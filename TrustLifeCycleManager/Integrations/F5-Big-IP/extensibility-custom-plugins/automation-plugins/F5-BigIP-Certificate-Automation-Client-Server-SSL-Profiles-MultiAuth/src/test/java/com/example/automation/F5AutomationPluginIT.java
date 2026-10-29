package com.example.automation;

import static com.github.tomakehurst.wiremock.client.WireMock.aResponse;
import static com.github.tomakehurst.wiremock.client.WireMock.get;
import static com.github.tomakehurst.wiremock.client.WireMock.urlPathMatching;
import static com.github.tomakehurst.wiremock.core.WireMockConfiguration.wireMockConfig;
import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.mockito.ArgumentMatchers.anyBoolean;
import static org.mockito.ArgumentMatchers.anyMap;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.verifyNoInteractions;
import static org.mockito.Mockito.when;

import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.util.Base64;
import java.util.Map;
import java.util.zip.ZipEntry;
import java.util.zip.ZipOutputStream;

import com.digicert.tlm.workflows.WorkflowExecutionException;
import com.example.automation.adapter.F5SshAdapter;
import com.example.automation.adapter.F5iControlRestAdapter;
import com.example.automation.extended.configuration.MyPluginConfiguration;
import com.example.automation.model.Result;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.node.ObjectNode;
import com.github.tomakehurst.wiremock.junit5.WireMockExtension;

import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Tag;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.junit.jupiter.api.extension.RegisterExtension;
import org.mockito.ArgumentCaptor;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;

/**
 * Exercises the certificate download path: TLM hands the plugin a {@code certificateLink} to a ZIP
 * artifact, which the plugin downloads over HTTPS and unpacks before calling the SSH adapter.
 */
@Tag("integration")
@ExtendWith(MockitoExtension.class)
@SuppressWarnings("unchecked")
class F5AutomationPluginIT {

    private static final ObjectMapper MAPPER = new ObjectMapper();
    private static final String EE = "-----BEGIN CERTIFICATE-----\nMIIBee\n-----END CERTIFICATE-----\n";
    private static final String ICA = "-----BEGIN CERTIFICATE-----\nMIIBica\n-----END CERTIFICATE-----\n";

    @RegisterExtension
    static WireMockExtension wm = WireMockExtension.newInstance()
            .options(wireMockConfig().dynamicPort().dynamicHttpsPort())
            .build();

    @Mock
    private F5SshAdapter ssh;

    @Mock
    private F5iControlRestAdapter rest;

    @BeforeAll
    static void disableHostnameVerification() {
        System.setProperty("jdk.internal.httpclient.disableHostnameVerification", "true");
    }

    private static byte[] zip(Map<String, String> entries) throws IOException {
        final var bytes = new ByteArrayOutputStream();
        try (ZipOutputStream zos = new ZipOutputStream(bytes)) {
            for (var entry : entries.entrySet()) {
                zos.putNextEntry(new ZipEntry(entry.getKey()));
                zos.write(entry.getValue().getBytes(StandardCharsets.UTF_8));
                zos.closeEntry();
            }
        }
        return bytes.toByteArray();
    }

    private F5AutomationPlugin plugin() {
        final var config = new MyPluginConfiguration();
        config.setManagementIp("10.0.0.1");
        config.setManagementPort("443");
        config.setUserName("admin");
        config.setPassword(Base64.getEncoder().encodeToString("secret".getBytes()));
        return new F5AutomationPlugin(config, rest, ssh);
    }

    private ObjectNode installRequest(String link) {
        final var node = MAPPER.createObjectNode();
        node.put("flowId", "8a265aeb-451c-44b7-a1fd-3ec00c98c4e0");
        node.put("flowStartDate", "2026-01-28T22:47:09Z");
        node.put("subjectDn", "CN=www.example.com,O=Example Inc,C=US");
        node.put("virtualServerName", "/Common/vs_example");
        node.put("currentCertificateThumbprint", "AABBCC");
        node.put("certificateLink", link);
        return node;
    }

    @Test
    @DisplayName("certificateLink: the TLM ZIP is downloaded over HTTPS and its .cer entries reach the adapter")
    void installDownloadsArtifact() throws Exception {
        wm.stubFor(get(urlPathMatching("/mpki/api/v1/ts/artifact/.*"))
                .willReturn(aResponse().withStatus(200)
                        .withHeader("Content-Type", "application/zip")
                        .withBody(zip(Map.of(
                                "www.example.com.p7b", "pkcs7",
                                "www.example.com.cer", EE,
                                "www.example.com_ica.cer", ICA)))));
        when(ssh.installCertificate(anyString(), anyString(), anyMap(), anyString(), anyBoolean(), anyBoolean(),
                anyBoolean(), anyBoolean())).thenReturn(Result.success());

        final var link = "https://localhost:" + wm.getHttpsPort() + "/mpki/api/v1/ts/artifact/23b7b411";
        final var response = plugin().installCertificate(installRequest(link));

        assertNull(response.getErrors());
        final var certs = ArgumentCaptor.forClass(Map.class);
        verify(ssh).installCertificate(eq("www.example.com_20260128T224709Z_8a265aeb"), eq("/Common/vs_example"),
                certs.capture(), eq("AABBCC"), eq(true), eq(false), eq(true), eq(false));
        assertEquals(EE, certs.getValue().get("end_entity.cer"));
        assertEquals(ICA, certs.getValue().get("ica.cer"));
    }

    @Test
    @DisplayName("artifact download failure (404) surfaces as WorkflowExecutionException before any SSH call")
    void installDownloadFails() {
        wm.stubFor(get(urlPathMatching("/mpki/api/v1/ts/artifact/.*"))
                .willReturn(aResponse().withStatus(404)));

        final var link = "https://localhost:" + wm.getHttpsPort() + "/mpki/api/v1/ts/artifact/missing";
        assertThrows(WorkflowExecutionException.class, () -> plugin().installCertificate(installRequest(link)));
        verifyNoInteractions(ssh);
    }

    @Test
    @DisplayName("artifact without an end-entity .cer is rejected before any SSH call")
    void installArtifactWithoutEndEntity() throws Exception {
        wm.stubFor(get(urlPathMatching("/mpki/api/v1/ts/artifact/.*"))
                .willReturn(aResponse().withStatus(200)
                        .withBody(zip(Map.of("www.example.com.p7b", "pkcs7")))));

        final var link = "https://localhost:" + wm.getHttpsPort() + "/mpki/api/v1/ts/artifact/p7b-only";
        assertThrows(WorkflowExecutionException.class, () -> plugin().installCertificate(installRequest(link)));
        verifyNoInteractions(ssh);
    }
}
