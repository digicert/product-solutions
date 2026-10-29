package com.example.automation.adapter;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertTrue;
import static org.mockito.ArgumentMatchers.anyString;
import static org.mockito.ArgumentMatchers.eq;
import static org.mockito.Mockito.verify;
import static org.mockito.Mockito.when;

import java.io.IOException;
import java.io.StringWriter;
import java.math.BigInteger;
import java.nio.charset.StandardCharsets;
import java.security.KeyPairGenerator;
import java.security.Security;
import java.security.cert.X509Certificate;
import java.util.Base64;
import java.util.Date;
import java.util.List;
import java.util.Map;

import javax.security.auth.x500.X500Principal;

import com.example.automation.model.ErrorCode;
import com.example.automation.util.ssh.SSHClient;
import com.example.automation.util.ssh.SshResponse;
import com.fasterxml.jackson.core.type.TypeReference;
import com.fasterxml.jackson.databind.ObjectMapper;

import org.bouncycastle.cert.jcajce.JcaX509CertificateConverter;
import org.bouncycastle.cert.jcajce.JcaX509v3CertificateBuilder;
import org.bouncycastle.jce.provider.BouncyCastleProvider;
import org.bouncycastle.openssl.jcajce.JcaPEMWriter;
import org.bouncycastle.operator.jcajce.JcaContentSignerBuilder;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.extension.ExtendWith;
import org.mockito.ArgumentCaptor;
import org.mockito.Mock;
import org.mockito.junit.jupiter.MockitoExtension;

/**
 * The SSH client is mocked, so these tests pin down the contract between the Java side and the
 * device scripts: which script is run, and exactly what arguments or JSON payload it receives.
 */
@ExtendWith(MockitoExtension.class)
class F5SshAdapterTest {

    private static final ObjectMapper MAPPER = new ObjectMapper();
    private static final String VS = "/Common/vs_example";
    private static final String KEY_NAME = "www.example.com_20260129T231120Z_6855593c";
    private static final String THUMBPRINT = "9A1C65C28BE34B122F836238D7FF57DF52F09F78F112F0DB78EA957369FE5B61";
    private static final String EE = "-----BEGIN CERTIFICATE-----\nMIIBee 'quoted' $HOME\n-----END CERTIFICATE-----\n";

    /** Real ICA certificate with serial 123456789 (hex 75bcd15), generated once with BouncyCastle. */
    private static String icaPem;
    private static final String ICA_SERIAL_HEX = "75bcd15";

    @Mock
    private SSHClient sshClient;

    private F5SshAdapter adapter;

    @BeforeAll
    static void generateIca() throws Exception {
        if (Security.getProvider("BC") == null) {
            Security.addProvider(new BouncyCastleProvider());
        }
        final var kpg = KeyPairGenerator.getInstance("RSA", "BC");
        kpg.initialize(2048);
        final var kp = kpg.generateKeyPair();
        final var subject = new X500Principal("CN=Test ICA");
        final var now = new Date();
        final var builder = new JcaX509v3CertificateBuilder(subject, BigInteger.valueOf(123456789L), now,
                new Date(now.getTime() + 86_400_000L), subject, kp.getPublic());
        final var signer = new JcaContentSignerBuilder("SHA256WithRSA").setProvider("BC").build(kp.getPrivate());
        final X509Certificate cert = new JcaX509CertificateConverter().setProvider("BC")
                .getCertificate(builder.build(signer));
        final var sw = new StringWriter();
        try (JcaPEMWriter pw = new JcaPEMWriter(sw)) {
            pw.writeObject(cert);
        }
        icaPem = sw.toString();
    }

    @BeforeEach
    void setUp() {
        final var config = AdapterConfig.builder()
                .host("10.0.0.1").sshPort(22).username("admin").password("secret").build();
        adapter = new F5SshAdapter(config, sshClient);
    }

    private static SshResponse ok(String output) {
        return new SshResponse(output, 0);
    }

    private static SshResponse fail(String output) {
        return new SshResponse(output, 1);
    }

    private static Map<String, String> certs() {
        return Map.of("end_entity.cer", EE, "ica.cer", icaPem);
    }

    private Map<String, Object> capturedInstallPayload() throws IOException {
        final var captor = ArgumentCaptor.forClass(String.class);
        verify(sshClient).executePythonScript(eq(F5SshAdapter.INSTALL_CERTIFICATE_SCRIPT), captor.capture());
        final var args = captor.getValue();
        assertFalse(args.contains(" "), "install payload must be a single base64 token, got: " + args);
        final var json = new String(Base64.getDecoder().decode(args), StandardCharsets.UTF_8);
        return MAPPER.readValue(json, new TypeReference<>() { });
    }

    // ── testConnection ────────────────────────────────────────────────────────

    @Test
    @DisplayName("probe runs python and tmsh, success maps to an active connection")
    void probeSuccess() throws IOException {
        when(sshClient.executeRemoteCommand(F5SshAdapter.PROBE_COMMAND)).thenReturn(ok("python-ok\nSys::Version"));
        final var result = adapter.testConnection();
        assertTrue(result.isSuccess());
        assertTrue(result.getValue().isActive());
    }

    @Test
    @DisplayName("probe non-zero exit reports the first output line and INTERNAL_ERROR")
    void probeFailure() throws IOException {
        when(sshClient.executeRemoteCommand(anyString())).thenReturn(fail("-bash: python: command not found\nmore"));
        final var result = adapter.testConnection();
        assertFalse(result.isSuccess());
        assertEquals(ErrorCode.INTERNAL_ERROR.name(), result.getErrorCode());
        assertTrue(result.getErrorMessage().contains("python: command not found"));
        assertFalse(result.getErrorMessage().contains("more"));
    }

    @Test
    @DisplayName("probe IOException (auth failure, unreachable host) is a failure, not an exception")
    void probeIoException() throws IOException {
        when(sshClient.executeRemoteCommand(anyString())).thenThrow(new IOException("Connection refused"));
        final var result = adapter.testConnection();
        assertFalse(result.isSuccess());
        assertTrue(result.getErrorMessage().contains("Connection refused"));
    }

    // ── generateCsr ───────────────────────────────────────────────────────────

    @Test
    @DisplayName("generate-csr.py receives nine positional arguments in the documented order")
    void generateCsrArguments() throws IOException {
        when(sshClient.executePythonScript(eq(F5SshAdapter.GENERATE_CSR_SCRIPT), anyString()))
                .thenReturn(ok("{\"csr\": \"-----BEGIN CERTIFICATE REQUEST-----\"}"));

        final var result = adapter.generateCsr(VS, "www.example.com", List.of("a.example.com", "b.example.com"),
                KEY_NAME, "2048", "rsa-private", F5SshAdapter.KeyStorage.FIPS,
                Map.of("organization", "Example Inc"), true);

        assertTrue(result.isSuccess());
        assertEquals("-----BEGIN CERTIFICATE REQUEST-----", result.getValue().getCsr());

        final var captor = ArgumentCaptor.forClass(String.class);
        verify(sshClient).executePythonScript(eq(F5SshAdapter.GENERATE_CSR_SCRIPT), captor.capture());
        final var args = captor.getValue().split(" ");
        assertEquals(9, args.length, String.join(" | ", args));
        assertEquals(VS, args[0]);
        assertEquals("www.example.com", args[1]);
        assertEquals("\"DNS:a.example.com,DNS:b.example.com\"", args[2]);
        assertEquals(KEY_NAME, args[3]);
        assertEquals("2048", args[4]);
        assertEquals("rsa-private", args[5]);
        assertEquals("fips", args[6]);
        final var subjectFields = new String(Base64.getDecoder().decode(args[7]), StandardCharsets.UTF_8);
        assertEquals("{\"organization\":\"Example Inc\"}", subjectFields);
        assertEquals("true", args[8]);
    }

    @Test
    @DisplayName("empty SANs and subject fields use the sentinel markers, NET_HSM maps to nethsm, sync false")
    void generateCsrSentinels() throws IOException {
        when(sshClient.executePythonScript(eq(F5SshAdapter.GENERATE_CSR_SCRIPT), anyString()))
                .thenReturn(ok("{\"csr\": \"csr\"}"));

        adapter.generateCsr(VS, "cn", List.of(), KEY_NAME, "256", "ec-private",
                F5SshAdapter.KeyStorage.NET_HSM, Map.of(), false);

        final var captor = ArgumentCaptor.forClass(String.class);
        verify(sshClient).executePythonScript(eq(F5SshAdapter.GENERATE_CSR_SCRIPT), captor.capture());
        final var args = captor.getValue().split(" ");
        assertEquals("EMPTY_DNS_NAMES", args[2]);
        assertEquals("nethsm", args[6]);
        assertEquals("EMPTY_SUBJECT_DN_FIELDS", args[7]);
        assertEquals("false", args[8]);
    }

    @Test
    @DisplayName("script error JSON is mapped to Result.failure(message, code)")
    void generateCsrScriptError() throws IOException {
        when(sshClient.executePythonScript(eq(F5SshAdapter.GENERATE_CSR_SCRIPT), anyString()))
                .thenReturn(fail("{\"error\": \"Key already exists\", \"code\": \"CSR_GENERATION_ERROR\"}"));

        final var result = adapter.generateCsr(VS, "cn", List.of(), KEY_NAME, "2048", "rsa-private",
                F5SshAdapter.KeyStorage.NORMAL, Map.of(), false);

        assertFalse(result.isSuccess());
        assertEquals("Key already exists", result.getErrorMessage());
        assertEquals("CSR_GENERATION_ERROR", result.getErrorCode());
    }

    @Test
    @DisplayName("non-JSON script output (python missing, tmsh banner) becomes INTERNAL_ERROR with the first line")
    void generateCsrNonJsonError() throws IOException {
        when(sshClient.executePythonScript(eq(F5SshAdapter.GENERATE_CSR_SCRIPT), anyString()))
                .thenReturn(fail("Syntax Error: unexpected argument \"python\"\nsecond line"));

        final var result = adapter.generateCsr(VS, "cn", List.of(), KEY_NAME, "2048", "rsa-private",
                null, null, false);

        assertFalse(result.isSuccess());
        assertEquals(ErrorCode.INTERNAL_ERROR.name(), result.getErrorCode());
        assertTrue(result.getErrorMessage().contains("Syntax Error"));
    }

    // ── installCertificate ────────────────────────────────────────────────────

    @Test
    @DisplayName("install-certificate.py receives one base64 JSON document with every named field")
    void installPayload() throws IOException {
        when(sshClient.executePythonScript(eq(F5SshAdapter.INSTALL_CERTIFICATE_SCRIPT), anyString()))
                .thenReturn(ok("{\"success\": true, \"info\": [\"HA sync performed\"], \"server-ssl-profiles-updated\": []}"));

        final var result = adapter.installCertificate(KEY_NAME, VS, certs(), THUMBPRINT,
                true, false, true, true);
        assertTrue(result.isSuccess());

        final var payload = capturedInstallPayload();
        assertEquals(VS, payload.get("virtualServerName"));
        assertEquals(THUMBPRINT, payload.get("currentCertificateThumbprint"));
        assertEquals(KEY_NAME, payload.get("keyName"));
        assertEquals(Boolean.TRUE, payload.get("updateSameSslProfile"));
        assertEquals(Boolean.FALSE, payload.get("useCommonIca"));
        assertNull(payload.get("icaSerialNum"));
        assertEquals(EE, payload.get("endEntityCertificate"));
        assertEquals(icaPem, payload.get("icaCertificate"));
        assertEquals(Boolean.TRUE, payload.get("updateServerSslProfile"));
        assertEquals(Boolean.TRUE, payload.get("groupSyncEnabled"));
    }

    @Test
    @DisplayName("useCommonIca adds the ICA serial in lower-case hex taken from the real certificate")
    void installCommonIcaSerial() throws IOException {
        when(sshClient.executePythonScript(eq(F5SshAdapter.INSTALL_CERTIFICATE_SCRIPT), anyString()))
                .thenReturn(ok("{\"success\": true}"));

        adapter.installCertificate(KEY_NAME, VS, certs(), THUMBPRINT, false, true, false, false);

        final var payload = capturedInstallPayload();
        assertEquals(ICA_SERIAL_HEX, payload.get("icaSerialNum"));
        assertEquals(Boolean.TRUE, payload.get("useCommonIca"));
        assertEquals(Boolean.FALSE, payload.get("updateServerSslProfile"));
        assertEquals(Boolean.FALSE, payload.get("groupSyncEnabled"));
    }

    @Test
    @DisplayName("unsecured VIP: null thumbprint and missing ICA travel as JSON null and empty string")
    void installUnsecuredVip() throws IOException {
        when(sshClient.executePythonScript(eq(F5SshAdapter.INSTALL_CERTIFICATE_SCRIPT), anyString()))
                .thenReturn(ok("{\"success\": true}"));

        adapter.installCertificate(KEY_NAME, VS, Map.of("end_entity.cer", EE), null, true, false, true, false);

        final var payload = capturedInstallPayload();
        assertTrue(payload.containsKey("currentCertificateThumbprint"));
        assertNull(payload.get("currentCertificateThumbprint"));
        assertEquals("", payload.get("icaCertificate"));
    }

    @Test
    @DisplayName("install script error JSON is surfaced with its code")
    void installScriptError() throws IOException {
        when(sshClient.executePythonScript(eq(F5SshAdapter.INSTALL_CERTIFICATE_SCRIPT), anyString()))
                .thenReturn(fail("{\"error\": \"No client-ssl profile on virtual server\", \"code\": \"CLIENT_SSL_PROFILE_NOT_FOUND\"}"));

        final var result = adapter.installCertificate(KEY_NAME, VS, certs(), THUMBPRINT, true, false, true, false);

        assertFalse(result.isSuccess());
        assertEquals("CLIENT_SSL_PROFILE_NOT_FOUND", result.getErrorCode());
    }

    @Test
    @DisplayName("install IOException maps to INTERNAL_ERROR")
    void installIoException() throws IOException {
        when(sshClient.executePythonScript(eq(F5SshAdapter.INSTALL_CERTIFICATE_SCRIPT), anyString()))
                .thenThrow(new IOException("SSH timeout"));

        final var result = adapter.installCertificate(KEY_NAME, VS, certs(), THUMBPRINT, true, false, true, false);

        assertFalse(result.isSuccess());
        assertEquals(ErrorCode.INTERNAL_ERROR.name(), result.getErrorCode());
        assertEquals("SSH timeout", result.getErrorMessage());
    }

    // ── validateCertificate ───────────────────────────────────────────────────

    @Test
    @DisplayName("validate-certificate.py receives virtual server then key name and returns the PEM")
    void validateArguments() throws IOException {
        when(sshClient.executePythonScript(eq(F5SshAdapter.VALIDATE_CERTIFICATE_SCRIPT), eq(VS + " " + KEY_NAME)))
                .thenReturn(ok("{\"certificate\": \"-----BEGIN CERTIFICATE-----\"}"));

        final var result = adapter.validateCertificate(KEY_NAME, VS);

        assertTrue(result.isSuccess());
        assertEquals("-----BEGIN CERTIFICATE-----", result.getValue().getCertificate());
    }

    @Test
    @DisplayName("validate not-found error is surfaced with its code")
    void validateNotFound() throws IOException {
        when(sshClient.executePythonScript(eq(F5SshAdapter.VALIDATE_CERTIFICATE_SCRIPT), anyString()))
                .thenReturn(fail("{\"error\": \"Certificate x.crt not found\", \"code\": \"CERTIFICATE_VALIDATION_ERROR\"}"));

        final var result = adapter.validateCertificate(KEY_NAME, VS);

        assertFalse(result.isSuccess());
        assertEquals("CERTIFICATE_VALIDATION_ERROR", result.getErrorCode());
    }

    // ── getVirtualServersInfo ─────────────────────────────────────────────────

    @Test
    @DisplayName("get-configuration-info.py JSON is parsed into F5ConfigurationData, unknown keys ignored")
    void refreshParsesConfiguration() throws IOException {
        final var json = """
                {
                  "system-info": {"product": "BIG-IP", "version": "17.5.1.9", "hostname": "bigip01"},
                  "vips": [{"destination": "10.0.0.1:443", "partition": "Common", "ip": "10.0.0.1",
                            "port": "443", "virtual-server-name": "Common/vs_example", "ssl-state": 1}],
                  "skipped-vips": [],
                  "certificates": [{"cert": "/Common/a.crt", "destination": "10.0.0.1:443", "ip": "10.0.0.1",
                                    "port": "443", "cipher-discovery": "TLS_AES_256_GCM_SHA384", "sni": true}],
                  "peers": [{"management-ip": "10.0.0.2", "failover-state": "standby"}],
                  "partitions": ["Common"],
                  "future-field": "ignored"
                }
                """;
        when(sshClient.executePythonScript(eq(F5SshAdapter.GET_CONFIGURATION_SCRIPT), eq(""))).thenReturn(ok(json));

        final var result = adapter.getVirtualServersInfo();

        assertTrue(result.isSuccess());
        final var data = result.getValue();
        assertEquals("bigip01", data.getSystemVersionDetails().getHostname());
        assertEquals("Common/vs_example", data.getVirtualServers().get(0).getVirtualServerName());
        assertEquals(1, data.getVirtualServers().get(0).getSslState());
        assertTrue(data.getCertificates().get(0).isSni());
        assertEquals("standby", data.getPeers().get(0).getFailoverState());
    }
}
