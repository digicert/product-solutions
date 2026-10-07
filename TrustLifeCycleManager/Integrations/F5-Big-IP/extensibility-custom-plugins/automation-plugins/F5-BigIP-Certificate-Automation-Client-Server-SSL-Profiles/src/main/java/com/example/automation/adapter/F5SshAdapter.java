package com.example.automation.adapter;

import java.io.ByteArrayInputStream;
import java.io.IOException;
import java.io.InputStream;
import java.math.BigInteger;
import java.nio.charset.StandardCharsets;
import java.security.cert.CertificateFactory;
import java.security.cert.X509Certificate;
import java.util.Base64;
import java.util.List;
import java.util.Map;
import java.util.stream.Collectors;

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
 */
@Slf4j
public class F5SshAdapter {

    public enum KeyStorage {
        NORMAL,
        FIPS,
        NET_HSM
    }

    private static final ObjectMapper objectMapper = new ObjectMapper()
            .configure(DeserializationFeature.FAIL_ON_UNKNOWN_PROPERTIES, false);

    private final AdapterConfig adapterConfig;
    private final SSHClient sshClient;

    public F5SshAdapter(AdapterConfig config) {
        this.adapterConfig = config;
        this.sshClient = new SSHClient(config.getHost(), config.getUsername(), config.getPassword());
    }

    public Result<Connection> testConnection() {
        final var command = String.format("tmsh -a list auth user %s", adapterConfig.getUsername());
        final SshResponse sshResponse;
        try {
            sshResponse = sshClient.executeRemoteCommand(command);
        } catch (IOException e) {
            log.error("SSH error running [{}] on {}@{}",
                    command, adapterConfig.getUsername(), adapterConfig.getHost(), e);
            return Result.failure(e.getMessage(), ErrorCode.INTERNAL_ERROR.name());
        }

        if (sshResponse.isSuccess()) {
            return Result.success(new Connection(true));
        }
        log.error("SSH response not successful: [command={}, output={}, host={}, user={}]",
                command, sshResponse.getOutput(), adapterConfig.getHost(), adapterConfig.getUsername());
        return Result.failure("Internal error", ErrorCode.INTERNAL_ERROR.name());
    }

    @SneakyThrows
    public Result<F5ConfigurationData> getVirtualServersInfo() {
        final var script = "/ssh-scripts/get-configuration-info.py";
        final SshResponse sshResponse;
        try {
            sshResponse = sshClient.executePythonScript(script, "");
        } catch (IOException e) {
            log.error("SSH error executing {} on {}@{}",
                    script, adapterConfig.getUsername(), adapterConfig.getHost(), e);
            return Result.failure(e.getMessage(), ErrorCode.INTERNAL_ERROR.name());
        }

        if (sshResponse.isSuccess()) {
            final var configurationData =
                    objectMapper.readValue(sshResponse.getOutput(), F5ConfigurationData.class);
            return Result.success(configurationData);
        }
        log.error("SSH script {} failed: output={}", script, sshResponse.getOutput());
        final var f5Error = objectMapper.readValue(sshResponse.getOutput(), F5Error.class);
        return Result.failure(f5Error.getMessage(), f5Error.getCode());
    }

    @SneakyThrows
    public Result<F5GeneratedCsr> generateCsr(
            String virtualServerName,
            String commonName,
            List<String> dnsNames,
            String keyName,
            String keySize,
            String keyType,
            KeyStorage keyStorage,
            Map<String, String> subjectDnFields) {
        final var script = "/ssh-scripts/generate-csr.py";

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

        final var args = String.format("%s %s %s %s %s %s %s %s",
                virtualServerName, commonName, formattedDnsNames, keyName, keySize, keyType,
                keySecurityType, subjectDnFieldsJson);

        final SshResponse sshResponse;
        try {
            sshResponse = sshClient.executePythonScript(script, args);
        } catch (IOException e) {
            log.error("SSH error executing {} on {}@{}",
                    script, adapterConfig.getUsername(), adapterConfig.getHost(), e);
            return Result.failure(e.getMessage(), ErrorCode.INTERNAL_ERROR.name());
        }

        if (sshResponse.isSuccess()) {
            final var generated = objectMapper.readValue(sshResponse.getOutput(), F5GeneratedCsr.class);
            if (generated.getWarnings() != null && !generated.getWarnings().isEmpty()) {
                log.warn("CSR generation warnings: {}", generated.getWarnings());
            }
            return Result.success(generated);
        }
        log.error("SSH script {} failed: output={}", script, sshResponse.getOutput());
        final var f5Error = objectMapper.readValue(sshResponse.getOutput(), F5Error.class);
        return Result.failure(f5Error.getMessage(), f5Error.getCode());
    }

    @SneakyThrows
    public Result<Void> installCertificate(
            String keyName,
            String virtualServerName,
            Map<String, String> certificates,
            String currentCertificateThumbprint,
            boolean updateSameSslProfile,
            boolean useCommonIca,
            boolean updateServerSslProfile) {
        final var script = "/ssh-scripts/install-certificate.py";
        final var endEntityCertificate = certificates.get("end_entity.cer");
        final var icaCertificate = certificates.get("ica.cer");

        String icaSerialNum = "null";
        if (useCommonIca && icaCertificate != null) {
            try (InputStream in = new ByteArrayInputStream(icaCertificate.getBytes(StandardCharsets.UTF_8))) {
                CertificateFactory cf = CertificateFactory.getInstance("X.509");
                X509Certificate cert = (X509Certificate) cf.generateCertificate(in);
                icaSerialNum = new BigInteger(1, cert.getSerialNumber().toByteArray()).toString(16);
            }
        }

        // Argument 9 (updateServerSslProfile) was added later; the script defaults it to true when absent.
        final var args = String.format(
                "%s %s %s %b %b %s \"%s\" \"%s\" %b",
                virtualServerName,
                currentCertificateThumbprint == null ? "null" : currentCertificateThumbprint,
                keyName,
                updateSameSslProfile,
                useCommonIca,
                icaSerialNum,
                endEntityCertificate == null ? "" : endEntityCertificate,
                icaCertificate == null ? "" : icaCertificate,
                updateServerSslProfile);

        final SshResponse sshResponse;
        try {
            sshResponse = sshClient.executePythonScript(script, args);
        } catch (IOException e) {
            log.error("SSH error executing {} on {}@{}",
                    script, adapterConfig.getUsername(), adapterConfig.getHost(), e);
            return Result.failure(e.getMessage(), ErrorCode.INTERNAL_ERROR.name());
        }

        if (sshResponse.isSuccess()) {
            return Result.success();
        }
        log.error("SSH script {} failed: output={}", script, sshResponse.getOutput());
        final var f5Error = objectMapper.readValue(sshResponse.getOutput(), F5Error.class);
        return Result.failure(f5Error.getMessage(), f5Error.getCode());
    }

    @SneakyThrows
    public Result<F5InstalledCertificate> validateCertificate(String keyName, String virtualServerName) {
        final var script = "/ssh-scripts/validate-certificate.py";
        final var args = String.format("%s %s", virtualServerName, keyName);

        final SshResponse sshResponse;
        try {
            sshResponse = sshClient.executePythonScript(script, args);
        } catch (IOException e) {
            log.error("SSH error executing {} on {}@{}",
                    script, adapterConfig.getUsername(), adapterConfig.getHost(), e);
            return Result.failure(e.getMessage(), ErrorCode.INTERNAL_ERROR.name());
        }

        if (sshResponse.isSuccess()) {
            final var installed = objectMapper.readValue(sshResponse.getOutput(), F5InstalledCertificate.class);
            return Result.success(installed);
        }
        log.error("SSH script {} failed: output={}", script, sshResponse.getOutput());
        final var f5Error = objectMapper.readValue(sshResponse.getOutput(), F5Error.class);
        return Result.failure(f5Error.getMessage(), f5Error.getCode());
    }
}
