package com.example.automation.adapter;

import java.io.ByteArrayInputStream;
import java.io.IOException;
import java.io.InputStream;
import java.math.BigInteger;
import java.nio.charset.StandardCharsets;
import java.security.cert.CertificateFactory;
import java.security.cert.X509Certificate;
import java.util.Base64;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.stream.Collectors;

import com.example.automation.model.BaseScriptResponse;
import com.example.automation.model.Connection;
import com.example.automation.model.ErrorCode;
import com.example.automation.model.F5ConfigurationData;
import com.example.automation.model.F5Error;
import com.example.automation.model.F5GeneratedCsr;
import com.example.automation.model.F5InstalledCertificate;
import com.example.automation.model.Result;
import com.example.automation.util.ssh.SSHClient;
import com.example.automation.util.ssh.SshResponse;
import com.fasterxml.jackson.databind.DeserializationFeature;
import com.fasterxml.jackson.databind.ObjectMapper;

import lombok.SneakyThrows;
import lombok.extern.slf4j.Slf4j;

/**
 * Wraps SSH/Python-script interactions with an F5 BIG-IP. Each method ships one of the bundled
 * scripts to the device over SSH, executes it with the given arguments, and parses the JSON
 * response into typed models. Non-zero exit codes are decoded as {@link F5Error}.
 * <p>
 * Argument contract: {@code generate-csr.py} and {@code validate-certificate.py} take positional
 * arguments. {@code install-certificate.py} takes a single base64-encoded JSON document (see
 * {@link #buildInstallPayload}) so the PEM blocks never touch the shell and new fields can be added
 * without renumbering positions.
 */
@Slf4j
public class F5SshAdapter {

    public enum KeyStorage {
        NORMAL,
        FIPS,
        NET_HSM
    }

    static final String GENERATE_CSR_SCRIPT = "/ssh-scripts/generate-csr.py";
    static final String INSTALL_CERTIFICATE_SCRIPT = "/ssh-scripts/install-certificate.py";
    static final String VALIDATE_CERTIFICATE_SCRIPT = "/ssh-scripts/validate-certificate.py";
    static final String GET_CONFIGURATION_SCRIPT = "/ssh-scripts/get-configuration-info.py";

    private static final ObjectMapper objectMapper = new ObjectMapper()
            .configure(DeserializationFeature.FAIL_ON_UNKNOWN_PROPERTIES, false);

    private final AdapterConfig adapterConfig;
    private final SSHClient sshClient;

    /**
     * Identity-agnostic probe that exercises exactly what the lifecycle scripts need: a working
     * {@code python} interpreter and the ability to run {@code tmsh}. Works for local users, root and
     * RADIUS/TACACS/LDAP remote users alike. The previous probe listed the connector user as a tmsh
     * auth user, which only exists for local accounts. If the account's login shell is tmsh the
     * {@link SSHClient} wraps the probe (and every other command) with {@code run /util bash -c}.
     */
    static final String PROBE_COMMAND = "python -c \"print('python-ok')\" && tmsh show sys version";

    public F5SshAdapter(AdapterConfig config) {
        this(config, new SSHClient(config.getHost(),
                config.getSshPort() == null ? 22 : config.getSshPort(),
                config.getUsername(), config.getPassword()));
    }

    /** Test seam: lets unit tests supply a mocked {@link SSHClient}. */
    F5SshAdapter(AdapterConfig config, SSHClient sshClient) {
        this.adapterConfig = config;
        this.sshClient = sshClient;
    }

    public Result<Connection> testConnection() {
        final SshResponse sshResponse;
        try {
            sshResponse = sshClient.executeRemoteCommand(PROBE_COMMAND);
        } catch (IOException e) {
            log.error("SSH error running [{}] on {}@{}:{}",
                    PROBE_COMMAND, adapterConfig.getUsername(), adapterConfig.getHost(),
                    adapterConfig.getSshPort(), e);
            return Result.failure("SSH connection failed: " + e.getMessage(), ErrorCode.INTERNAL_ERROR.name());
        }

        if (sshResponse.isSuccess()) {
            return Result.success(new Connection(true));
        }
        log.error("SSH probe not successful: [command={}, output={}, host={}, user={}]",
                PROBE_COMMAND, sshResponse.getOutput(), adapterConfig.getHost(), adapterConfig.getUsername());
        return Result.failure(
                "SSH probe failed (the SSH user needs python and tmsh available; Advanced shell or tmsh terminal access): "
                        + firstLine(sshResponse.getOutput()),
                ErrorCode.INTERNAL_ERROR.name());
    }

    private static String firstLine(String output) {
        if (output == null) {
            return "";
        }
        final var trimmed = output.strip();
        final var newline = trimmed.indexOf('\n');
        return newline < 0 ? trimmed : trimmed.substring(0, newline);
    }

    @SneakyThrows
    public Result<F5ConfigurationData> getVirtualServersInfo() {
        final SshResponse sshResponse;
        try {
            sshResponse = sshClient.executePythonScript(GET_CONFIGURATION_SCRIPT, "");
        } catch (IOException e) {
            log.error("SSH error executing {} on {}@{}",
                    GET_CONFIGURATION_SCRIPT, adapterConfig.getUsername(), adapterConfig.getHost(), e);
            return Result.failure(e.getMessage(), ErrorCode.INTERNAL_ERROR.name());
        }

        if (sshResponse.isSuccess()) {
            final var configurationData =
                    objectMapper.readValue(sshResponse.getOutput(), F5ConfigurationData.class);
            return Result.success(configurationData);
        }
        return scriptFailure(GET_CONFIGURATION_SCRIPT, sshResponse);
    }

    /**
     * Positional arguments: virtualServerName commonName dnsNames keyName keySize keyType keyStorage
     * subjectDnFieldsBase64 groupSyncEnabled. The script defaults the ninth argument to false when absent.
     */
    @SneakyThrows
    public Result<F5GeneratedCsr> generateCsr(
            String virtualServerName,
            String commonName,
            List<String> dnsNames,
            String keyName,
            String keySize,
            String keyType,
            KeyStorage keyStorage,
            Map<String, String> subjectDnFields,
            boolean groupSyncEnabled) {
        var formattedDnsNames = "EMPTY_DNS_NAMES";
        if (dnsNames != null && !dnsNames.isEmpty()) {
            formattedDnsNames = dnsNames.stream()
                    .map(name -> String.format("DNS:%s", name))
                    .collect(Collectors.joining(",", "\"", "\""));
        }

        final var keySecurityType = switch (keyStorage == null ? KeyStorage.NORMAL : keyStorage) {
            case FIPS -> "fips";
            case NET_HSM -> "nethsm";
            case NORMAL -> "normal";
        };

        final var subjectDnFieldsJson = subjectDnFields != null && !subjectDnFields.isEmpty()
                ? Base64.getEncoder().encodeToString(
                        objectMapper.writeValueAsString(subjectDnFields).getBytes(StandardCharsets.UTF_8))
                : "EMPTY_SUBJECT_DN_FIELDS";

        final var args = String.format("%s %s %s %s %s %s %s %s %b",
                virtualServerName, commonName, formattedDnsNames, keyName, keySize, keyType,
                keySecurityType, subjectDnFieldsJson, groupSyncEnabled);

        log.info("generateCsr started [virtualServer={}, keyName={}, groupSync={}]",
                virtualServerName, keyName, groupSyncEnabled ? "enabled" : "disabled");
        final SshResponse sshResponse;
        try {
            sshResponse = sshClient.executePythonScript(GENERATE_CSR_SCRIPT, args);
        } catch (IOException e) {
            log.error("SSH error executing {} on {}@{}",
                    GENERATE_CSR_SCRIPT, adapterConfig.getUsername(), adapterConfig.getHost(), e);
            return Result.failure(e.getMessage(), ErrorCode.INTERNAL_ERROR.name());
        }

        if (sshResponse.isSuccess()) {
            final var generated = objectMapper.readValue(sshResponse.getOutput(), F5GeneratedCsr.class);
            logScriptMessages(GENERATE_CSR_SCRIPT, generated);
            return Result.success(generated);
        }
        return scriptFailure(GENERATE_CSR_SCRIPT, sshResponse);
    }

    @SneakyThrows
    public Result<Void> installCertificate(
            String keyName,
            String virtualServerName,
            Map<String, String> certificates,
            String currentCertificateThumbprint,
            boolean updateSameSslProfile,
            boolean useCommonIca,
            boolean updateServerSslProfile,
            boolean groupSyncEnabled) {
        final var payload = buildInstallPayload(keyName, virtualServerName, certificates,
                currentCertificateThumbprint, updateSameSslProfile, useCommonIca,
                updateServerSslProfile, groupSyncEnabled);
        final var args = Base64.getEncoder().encodeToString(
                objectMapper.writeValueAsString(payload).getBytes(StandardCharsets.UTF_8));

        log.info("installCertificate started [virtualServer={}, keyName={}, updateSameSslProfile={}, "
                        + "useCommonIca={}, updateServerSslProfile={}, groupSync={}]",
                virtualServerName, keyName, updateSameSslProfile, useCommonIca, updateServerSslProfile,
                groupSyncEnabled ? "enabled" : "disabled");
        final SshResponse sshResponse;
        try {
            sshResponse = sshClient.executePythonScript(INSTALL_CERTIFICATE_SCRIPT, args);
        } catch (IOException e) {
            log.error("SSH error executing {} on {}@{}",
                    INSTALL_CERTIFICATE_SCRIPT, adapterConfig.getUsername(), adapterConfig.getHost(), e);
            return Result.failure(e.getMessage(), ErrorCode.INTERNAL_ERROR.name());
        }

        if (sshResponse.isSuccess()) {
            try {
                logScriptMessages(INSTALL_CERTIFICATE_SCRIPT,
                        objectMapper.readValue(sshResponse.getOutput(), BaseScriptResponse.class));
            } catch (IOException e) {
                log.debug("install-certificate.py output is not JSON: {}", sshResponse.getOutput());
            }
            return Result.success();
        }
        return scriptFailure(INSTALL_CERTIFICATE_SCRIPT, sshResponse);
    }

    /**
     * Builds the JSON document {@code install-certificate.py} reads. Keys match the ps-solutions
     * F5 plugin so the scripts stay interchangeable: {@code virtualServerName},
     * {@code currentCertificateThumbprint}, {@code keyName}, {@code updateSameSslProfile},
     * {@code useCommonIca}, {@code icaSerialNum}, {@code endEntityCertificate}, {@code icaCertificate},
     * {@code groupSyncEnabled}, plus {@code updateServerSslProfile} for this plugin's server-ssl handling.
     */
    @SneakyThrows
    static Map<String, Object> buildInstallPayload(
            String keyName,
            String virtualServerName,
            Map<String, String> certificates,
            String currentCertificateThumbprint,
            boolean updateSameSslProfile,
            boolean useCommonIca,
            boolean updateServerSslProfile,
            boolean groupSyncEnabled) {
        final var endEntityCertificate = certificates.get("end_entity.cer");
        final var icaCertificate = certificates.get("ica.cer");

        String icaSerialNum = null;
        if (useCommonIca && icaCertificate != null) {
            try (InputStream in = new ByteArrayInputStream(icaCertificate.getBytes(StandardCharsets.UTF_8))) {
                CertificateFactory cf = CertificateFactory.getInstance("X.509");
                X509Certificate cert = (X509Certificate) cf.generateCertificate(in);
                icaSerialNum = new BigInteger(1, cert.getSerialNumber().toByteArray()).toString(16);
            }
        }

        final Map<String, Object> payload = new LinkedHashMap<>();
        payload.put("virtualServerName", virtualServerName);
        payload.put("currentCertificateThumbprint", currentCertificateThumbprint);
        payload.put("keyName", keyName);
        payload.put("updateSameSslProfile", updateSameSslProfile);
        payload.put("useCommonIca", useCommonIca);
        payload.put("icaSerialNum", icaSerialNum);
        payload.put("endEntityCertificate", endEntityCertificate == null ? "" : endEntityCertificate);
        payload.put("icaCertificate", icaCertificate == null ? "" : icaCertificate);
        payload.put("updateServerSslProfile", updateServerSslProfile);
        payload.put("groupSyncEnabled", groupSyncEnabled);
        return payload;
    }

    @SneakyThrows
    public Result<F5InstalledCertificate> validateCertificate(String keyName, String virtualServerName) {
        final var args = String.format("%s %s", virtualServerName, keyName);

        final SshResponse sshResponse;
        try {
            sshResponse = sshClient.executePythonScript(VALIDATE_CERTIFICATE_SCRIPT, args);
        } catch (IOException e) {
            log.error("SSH error executing {} on {}@{}",
                    VALIDATE_CERTIFICATE_SCRIPT, adapterConfig.getUsername(), adapterConfig.getHost(), e);
            return Result.failure(e.getMessage(), ErrorCode.INTERNAL_ERROR.name());
        }

        if (sshResponse.isSuccess()) {
            final var installed = objectMapper.readValue(sshResponse.getOutput(), F5InstalledCertificate.class);
            return Result.success(installed);
        }
        return scriptFailure(VALIDATE_CERTIFICATE_SCRIPT, sshResponse);
    }

    private <T> Result<T> scriptFailure(String script, SshResponse sshResponse) {
        log.error("SSH script {} failed on {}@{}: exit={}, output={}", script,
                adapterConfig.getUsername(), adapterConfig.getHost(),
                sshResponse.getExitStatus(), sshResponse.getOutput());
        try {
            final var f5Error = objectMapper.readValue(sshResponse.getOutput(), F5Error.class);
            logScriptMessages(script, f5Error);
            if (f5Error.getMessage() == null && f5Error.getCode() == null) {
                return Result.failure("Script " + script + " failed: " + firstLine(sshResponse.getOutput()),
                        ErrorCode.INTERNAL_ERROR.name());
            }
            return Result.failure(f5Error.getMessage(),
                    f5Error.getCode() == null ? ErrorCode.INTERNAL_ERROR.name() : f5Error.getCode());
        } catch (IOException e) {
            // The device printed something that is not the script's JSON (python missing, tmsh banner, ...).
            return Result.failure("Script " + script + " failed: " + firstLine(sshResponse.getOutput()),
                    ErrorCode.INTERNAL_ERROR.name());
        }
    }

    private static void logScriptMessages(String script, BaseScriptResponse response) {
        if (response == null) {
            return;
        }
        if (response.getWarnings() != null && !response.getWarnings().isEmpty()) {
            log.warn("{} warnings: {}", script, response.getWarnings());
        }
        if (response.getInfo() != null && !response.getInfo().isEmpty()) {
            response.getInfo().forEach(message -> log.info("{}: {}", script, message));
        }
    }
}
