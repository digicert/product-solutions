package com.example.automation;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.mockito.ArgumentMatchers.any;
import static org.mockito.ArgumentMatchers.anyBoolean;
import static org.mockito.ArgumentMatchers.anyList;
import static org.mockito.ArgumentMatchers.anyMap;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.ArgumentMatchers.isNull;
import static org.mockito.Mockito.never;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.verifyNoInteractions;
import static org.mockito.Mockito.when;

import java.util.Base64;
import java.util.List;
import java.util.Map;

import com.digicert.tlm.workflows.WorkflowExecutionException;
import com.digicert.tlm.workflows.automation.dto.GenerateCsrResponse;
import com.digicert.tlm.workflows.automation.dto.InstallCertificateResponse;
import com.digicert.tlm.workflows.automation.dto.RefreshConfigurationResponse;
import com.digicert.tlm.workflows.automation.dto.TestConnectionResponse;
import com.digicert.tlm.workflows.automation.dto.ValidateCertificateResponse;
import com.example.automation.adapter.F5SshAdapter;
import com.example.automation.adapter.F5iControlRestAdapter;
import com.example.automation.extended.configuration.MyPluginConfiguration;
import com.example.automation.model.Connection;
import com.example.automation.model.ErrorCode;
import com.example.automation.model.F5ConfigurationData;
import com.example.automation.model.F5GeneratedCsr;
import com.example.automation.model.F5InstalledCertificate;
import com.example.automation.model.Result;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.node.ObjectNode;

import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.ArgumentCaptor;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;

/**
 * Plugin-level tests. Adapters are mocked through the package-private constructor; the request JSON
 * goes through the real SDK conversion so the flat TLM payload to extended-request mapping is covered.
 */
@ExtendWith(MockitoExtension.class)
@SuppressWarnings("unchecked")
class F5AutomationPluginTest {

    private static final ObjectMapper MAPPER = new ObjectMapper();
    private static final String FLOW_ID = "6855593c-ba92-49e4-8190-54d599979b52";
    private static final String FLOW_START = "2026-01-29T23:11:20Z";
    private static final String SUBJECT_DN = "CN=www.example.com,O=Example Inc,C=US";
    private static final String VS = "/Common/vs_example";
    private static final String EXPECTED_KEY_NAME = "www.example.com_20260129T231120Z_6855593c";
    private static final String EE = "-----BEGIN CERTIFICATE-----\nMIIBee\n-----END CERTIFICATE-----";
    private static final String ICA = "-----BEGIN CERTIFICATE-----\nMIIBica\n-----END CERTIFICATE-----";

    @Mock
    private F5SshAdapter ssh;

    @Mock
    private F5iControlRestAdapter rest;

    private static String b64(String value) {
        return Base64.getEncoder().encodeToString(value.getBytes());
    }

    private static MyPluginConfiguration sharedConfig() {
        final var config = new MyPluginConfiguration();
        config.setManagementIp("10.0.0.1");
        config.setManagementPort("443");
        config.setUserName("admin");
        config.setPassword(b64("secret"));
        return config;
    }

    private F5AutomationPlugin plugin(MyPluginConfiguration config) {
        return new F5AutomationPlugin(config, rest, ssh);
    }

    private static ObjectNode generateCsrRequest() {
        final var node = MAPPER.createObjectNode();
        node.put("flowId", FLOW_ID);
        node.put("flowStartDate", FLOW_START);
        node.put("subjectDn", SUBJECT_DN);
        node.put("dnsNames", "www.example.com, alt.example.com");
        node.put("signatureAlgorithm", "sha256");
        node.put("keyAlgorithm", "RSA");
        node.put("keySize", "2048");
        node.put("keyStorage", "fips");
        node.put("virtualServerName", VS);
        return node;
    }

    private static ObjectNode installRequest() {
        final var node = MAPPER.createObjectNode();
        node.put("flowId", FLOW_ID);
        node.put("flowStartDate", FLOW_START);
        node.put("subjectDn", SUBJECT_DN);
        node.put("virtualServerName", VS);
        node.put("currentCertificateThumbprint", "AABBCC");
        node.put("certificateChain", EE + "\n" + ICA);
        node.put("ipAddress", "10.0.0.1");
        node.put("port", "443");
        node.put("updateSameSslProfile", true);
        node.put("useCommonIca", true);
        return node;
    }

    private static ObjectNode validateRequest() {
        final var node = MAPPER.createObjectNode();
        node.put("flowId", FLOW_ID);
        node.put("flowStartDate", FLOW_START);
        node.put("subjectDn", SUBJECT_DN);
        node.put("virtualServerName", VS);
        return node;
    }

    private static F5ConfigurationData configurationData() {
        final var sys = new F5ConfigurationData.SystemVersionDetails();
        sys.setHostname("bigip01.example.com");
        sys.setProduct("BIG-IP");
        sys.setVersion("17.5.1.9");
        final var vs = new F5ConfigurationData.VirtualServer();
        vs.setIp("10.0.0.10");
        vs.setPort("443");
        vs.setPartition("Common");
        vs.setVirtualServerName("Common/vs_example");
        vs.setSslState(1);
        final var vsNoPort = new F5ConfigurationData.VirtualServer();
        vsNoPort.setIp("10.0.0.11");
        vsNoPort.setPartition("Common");
        vsNoPort.setVirtualServerName("Common/vs_any");
        final var cert = new F5ConfigurationData.Certificate();
        cert.setIp("10.0.0.10");
        cert.setPort("443");
        cert.setDestination("10.0.0.10:443");
        cert.setCert("/Common/www.example.com.crt");
        cert.setSni(true);
        cert.setCipherDiscovery("TLS_AES_256_GCM_SHA384");
        final var peer = new F5ConfigurationData.Peers();
        peer.setManagementIp("10.0.0.2");
        peer.setFailoverState("standby");
        final var data = new F5ConfigurationData();
        data.setSystemVersionDetails(sys);
        data.setVirtualServers(List.of(vs, vsNoPort));
        data.setCertificates(List.of(cert));
        data.setPeers(List.of(peer));
        data.setPartitions(List.of("Common", "Tenant1"));
        return data;
    }

    // ── testConnection ────────────────────────────────────────────────────────

    @Test
    @DisplayName("both probes succeed: active, no errors")
    void testConnectionActive() throws Exception {
        when(ssh.testConnection()).thenReturn(Result.success(new Connection(true)));
        when(rest.testConnection()).thenReturn(Result.success(new Connection(true)));

        final var response = (TestConnectionResponse<JsonNode>) plugin(sharedConfig()).testConnection(null);

        assertTrue(response.isActive());
        assertNull(response.getErrors());
    }

    @Test
    @DisplayName("SSH failure is prefixed with the SSH identity; REST still probed and reported")
    void testConnectionSshFails() throws Exception {
        when(ssh.testConnection()).thenReturn(Result.failure("probe failed", ErrorCode.INTERNAL_ERROR.name()));
        when(rest.testConnection()).thenReturn(Result.failure("Unauthorized", ErrorCode.UNAUTHORIZED.name()));

        final var response = (TestConnectionResponse<JsonNode>) plugin(sharedConfig()).testConnection(null);

        assertFalse(response.isActive());
        assertEquals(2, response.getErrors().size());
        assertEquals("SSH (admin@10.0.0.1:22): probe failed", response.getErrors().get(0).getMessage());
        assertEquals(ErrorCode.INTERNAL_ERROR.name(), response.getErrors().get(0).getStatus());
        assertEquals("REST (admin@10.0.0.1:443): Unauthorized", response.getErrors().get(1).getMessage());
        assertEquals(ErrorCode.UNAUTHORIZED.name(), response.getErrors().get(1).getStatus());
    }

    @Test
    @DisplayName("SEPARATE mode: error prefixes show the different identities per transport")
    void testConnectionSeparateIdentities() throws Exception {
        final var config = sharedConfig();
        config.setAuthMode("separate");
        config.setSshUserName("root");
        config.setSshPassword(b64("rootpw"));
        config.setSshPort("2222");
        when(ssh.testConnection()).thenReturn(Result.failure("denied", "X"));
        when(rest.testConnection()).thenReturn(Result.success(new Connection(true)));

        final var response = (TestConnectionResponse<JsonNode>) plugin(config).testConnection(null);

        assertFalse(response.isActive());
        assertEquals("SSH (root@10.0.0.1:2222): denied", response.getErrors().get(0).getMessage());
    }

    @Test
    @DisplayName("SSH_ONLY mode: no REST adapter is built and only SSH decides the outcome")
    void testConnectionSshOnly() throws Exception {
        final var config = sharedConfig();
        config.setAuthMode("ssh_only");
        when(ssh.testConnection()).thenReturn(Result.success(new Connection(true)));

        final var response = (TestConnectionResponse<JsonNode>)
                new F5AutomationPlugin(config, null, ssh).testConnection(null);

        assertTrue(response.isActive());
        assertNull(response.getErrors());
        verifyNoInteractions(rest);
    }

    // ── configuration errors ──────────────────────────────────────────────────

    @Test
    @DisplayName("invalid connector configuration: every action returns CONFIGURATION_ERROR without touching the device")
    void configurationErrorsShortCircuit() throws Exception {
        final var config = sharedConfig();
        config.setAuthMode("separate"); // no SSH credentials
        final var plugin = plugin(config);

        final var tc = (TestConnectionResponse<JsonNode>) plugin.testConnection(null);
        assertFalse(tc.isActive());
        assertEquals(ErrorCode.CONFIGURATION_ERROR.name(), tc.getErrors().get(0).getStatus());
        assertTrue(tc.getErrors().get(0).getMessage().contains("SSH username"));

        assertEquals(ErrorCode.CONFIGURATION_ERROR.name(),
                plugin.generateCsr(generateCsrRequest()).getErrors().get(0).getStatus());
        assertEquals(ErrorCode.CONFIGURATION_ERROR.name(),
                plugin.installCertificate(installRequest()).getErrors().get(0).getStatus());
        assertEquals(ErrorCode.CONFIGURATION_ERROR.name(),
                plugin.validateCertificate(validateRequest()).getErrors().get(0).getStatus());
        assertEquals(ErrorCode.CONFIGURATION_ERROR.name(),
                plugin.refreshConfiguration(MAPPER.createObjectNode()).getErrors().get(0).getStatus());

        verifyNoInteractions(ssh, rest);
    }

    // ── generateCsr ───────────────────────────────────────────────────────────

    @Test
    @DisplayName("generateCsr maps the flat TLM request onto the adapter call and returns the CSR")
    void generateCsrMapsRequest() throws Exception {
        final var generated = new F5GeneratedCsr();
        generated.setCsr("-----BEGIN CERTIFICATE REQUEST-----");
        when(ssh.generateCsr(anyString(), anyString(), anyList(), anyString(), anyString(), anyString(),
                any(), anyMap(), anyBoolean())).thenReturn(Result.success(generated));
        final var config = sharedConfig();
        config.setGroupSyncEnabled("true");

        final var response = (GenerateCsrResponse<JsonNode>) plugin(config).generateCsr(generateCsrRequest());

        assertEquals("-----BEGIN CERTIFICATE REQUEST-----", response.getCsr());
        assertNull(response.getErrors());

        final var dns = ArgumentCaptor.forClass(List.class);
        final var fields = ArgumentCaptor.forClass(Map.class);
        verify(ssh).generateCsr(eq(VS), eq("www.example.com"), dns.capture(), eq(EXPECTED_KEY_NAME),
                eq("2048"), eq("rsa-private"), eq(F5SshAdapter.KeyStorage.FIPS), fields.capture(), eq(true));
        assertEquals(List.of("www.example.com", "alt.example.com"), dns.getValue());
        assertEquals("Example Inc", fields.getValue().get("organization"));
        assertEquals("US", fields.getValue().get("country"));
    }

    @Test
    @DisplayName("generateCsr adapter failure is returned as a plugin error")
    void generateCsrFailure() throws Exception {
        when(ssh.generateCsr(anyString(), anyString(), anyList(), anyString(), anyString(), anyString(),
                any(), anyMap(), anyBoolean()))
                .thenReturn(Result.failure("Key exists", "CSR_GENERATION_ERROR"));

        final var response = plugin(sharedConfig()).generateCsr(generateCsrRequest());

        assertEquals(1, response.getErrors().size());
        assertEquals("CSR_GENERATION_ERROR", response.getErrors().get(0).getStatus());
        assertEquals("Key exists", response.getErrors().get(0).getMessage());
    }

    @Test
    @DisplayName("key algorithm and key storage mapping")
    void keyMappings() {
        assertEquals("rsa-private", F5AutomationPlugin.mapKeyType("RSA"));
        assertEquals("rsa-private", F5AutomationPlugin.mapKeyType(null));
        assertEquals("ec-private", F5AutomationPlugin.mapKeyType("ECDSA"));
        assertEquals(F5SshAdapter.KeyStorage.NORMAL, F5AutomationPlugin.mapKeyStorage(null));
        assertEquals(F5SshAdapter.KeyStorage.NORMAL, F5AutomationPlugin.mapKeyStorage("FILE_SYSTEM"));
        assertEquals(F5SshAdapter.KeyStorage.FIPS, F5AutomationPlugin.mapKeyStorage("FIPS"));
        assertEquals(F5SshAdapter.KeyStorage.NET_HSM, F5AutomationPlugin.mapKeyStorage("NET_HSM"));
        assertEquals(F5SshAdapter.KeyStorage.NET_HSM, F5AutomationPlugin.mapKeyStorage("nethsm"));
    }

    // ── installCertificate ────────────────────────────────────────────────────

    @Test
    @DisplayName("installCertificate: inline chain is split, connector settings override the request flag")
    void installUsesConnectorSettings() throws Exception {
        when(ssh.installCertificate(anyString(), anyString(), anyMap(), anyString(), anyBoolean(), anyBoolean(),
                anyBoolean(), anyBoolean())).thenReturn(Result.success());
        final var config = sharedConfig();
        config.setClientSslProfileMode("create");
        config.setUpdateServerSslProfile("false");
        config.setGroupSyncEnabled("true");

        final var response = (InstallCertificateResponse<JsonNode>) plugin(config).installCertificate(installRequest());

        assertNull(response.getErrors());
        final var certs = ArgumentCaptor.forClass(Map.class);
        verify(ssh).installCertificate(eq(EXPECTED_KEY_NAME), eq(VS), certs.capture(), eq("AABBCC"),
                eq(false),  // connector says "create", request flag true is ignored
                eq(true),   // useCommonIca from the request
                eq(false),  // connector disabled server-ssl updates
                eq(true));  // connector enabled HA sync
        assertEquals(EE + "\n", certs.getValue().get("end_entity.cer"));
        assertEquals(ICA + "\n", certs.getValue().get("ica.cer"));
    }

    @Test
    @DisplayName("installCertificate defaults: update profile in place, server-ssl on, HA sync off")
    void installDefaults() throws Exception {
        when(ssh.installCertificate(anyString(), anyString(), anyMap(), anyString(), anyBoolean(), anyBoolean(),
                anyBoolean(), anyBoolean())).thenReturn(Result.success());

        plugin(sharedConfig()).installCertificate(installRequest());

        verify(ssh).installCertificate(anyString(), anyString(), anyMap(), anyString(),
                eq(true), eq(true), eq(true), eq(false));
    }

    @Test
    @DisplayName("installCertificate without chain or link fails fast with WorkflowExecutionException")
    void installMissingCertSource() {
        final var request = installRequest();
        request.remove("certificateChain");

        assertThrows(WorkflowExecutionException.class, () -> plugin(sharedConfig()).installCertificate(request));
        verifyNoInteractions(ssh);
    }

    @Test
    @DisplayName("installCertificate adapter failure is returned as a plugin error")
    void installFailure() throws Exception {
        when(ssh.installCertificate(anyString(), anyString(), anyMap(), anyString(), anyBoolean(), anyBoolean(),
                anyBoolean(), anyBoolean()))
                .thenReturn(Result.failure("No client-ssl profile", "CLIENT_SSL_PROFILE_NOT_FOUND"));

        final var response = plugin(sharedConfig()).installCertificate(installRequest());

        assertEquals("CLIENT_SSL_PROFILE_NOT_FOUND", response.getErrors().get(0).getStatus());
    }

    // ── validateCertificate ───────────────────────────────────────────────────

    @Test
    @DisplayName("validateCertificate derives the same key name as CSR and install and returns the PEM")
    void validateSuccess() throws Exception {
        final var installed = new F5InstalledCertificate();
        installed.setCertificate(EE);
        when(ssh.validateCertificate(EXPECTED_KEY_NAME, VS)).thenReturn(Result.success(installed));

        final var response = (ValidateCertificateResponse<JsonNode>) plugin(sharedConfig()).validateCertificate(validateRequest());

        assertEquals(EE, response.getCertificate());
        assertNull(response.getErrors());
    }

    @Test
    @DisplayName("validateCertificate adapter failure is returned as a plugin error")
    void validateFailure() throws Exception {
        when(ssh.validateCertificate(anyString(), anyString()))
                .thenReturn(Result.failure("not found", "CERTIFICATE_VALIDATION_ERROR"));

        final var response = plugin(sharedConfig()).validateCertificate(validateRequest());

        assertEquals("CERTIFICATE_VALIDATION_ERROR", response.getErrors().get(0).getStatus());
    }

    // ── refreshConfiguration ──────────────────────────────────────────────────

    @Test
    @DisplayName("refreshConfiguration maps system info, virtual servers and certificates with null-safe fields")
    void refreshSuccess() throws Exception {
        when(ssh.getVirtualServersInfo()).thenReturn(Result.success(configurationData()));

        final var response = (RefreshConfigurationResponse<JsonNode>)
                plugin(sharedConfig()).refreshConfiguration(MAPPER.createObjectNode());

        assertNull(response.getErrors());
        final var info = response.getAutomationInfo();
        assertEquals("10.0.0.1", info.getManagementIp());
        assertEquals("bigip01.example.com", info.getHostName());
        assertEquals("BIGIP", info.getOsName());
        assertEquals("BIG-IP", info.getOsFlavor());
        assertEquals("17.5.1.9", info.getOsVersion());
        assertEquals(2, info.getDataIps().length);
        assertEquals("10.0.0.2:STANDBY", info.getPeerInfo());
        assertEquals(2, info.getPartitions().length);

        assertEquals(2, response.getDataIpInfo().size());
        final var first = response.getDataIpInfo().get(0);
        assertEquals("10.0.0.10", first.getDataIp());
        assertEquals(443, first.getPort());
        assertEquals("/Common", first.getPartition());
        assertEquals("Common/vs_example", first.getAlias());
        assertEquals(1, first.getSslState());
        assertNull(response.getDataIpInfo().get(1).getPort());

        assertEquals(1, response.getCertificates().size());
        final var cert = response.getCertificates().get(0);
        assertEquals("/Common/www.example.com.crt", cert.getCertificate());
        assertEquals("10.0.0.10:443", cert.getIpAndPort());
        assertTrue(cert.isSni());
        assertEquals("TLS_AES_256_GCM_SHA384", cert.getCipherDiscovery());
    }

    @Test
    @DisplayName("refreshConfiguration failure keeps the adapter's error after the JSON round-trip")
    void refreshFailure() throws Exception {
        when(ssh.getVirtualServersInfo()).thenReturn(Result.failure("python not found", "INTERNAL_ERROR"));

        final var response = plugin(sharedConfig()).refreshConfiguration(MAPPER.createObjectNode());

        assertNotNull(response.getErrors());
        assertEquals("INTERNAL_ERROR", response.getErrors().get(0).getStatus());
        assertEquals("python not found", response.getErrors().get(0).getMessage());
        verify(rest, never()).testConnection();
    }

    @Test
    @DisplayName("plugin version is read from plugin-meta.json on the classpath")
    void pluginVersion() {
        final var version = F5AutomationPlugin.readPluginVersion();
        assertNotNull(version);
        assertFalse(version.isBlank());
        assertFalse(version.contains("${"), "replacer plugin must substitute the version token: " + version);
    }
}
