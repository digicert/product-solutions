package com.example.automation;

import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.Base64;
import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.Optional;
import java.util.stream.Collectors;

import com.digicert.tlm.SdkContext;
import com.digicert.tlm.plugin.PluginError;
import com.digicert.tlm.plugin.PluginUtils;
import com.digicert.tlm.plugin.Response;
import com.digicert.tlm.plugin.WorkflowEntryPoint;
import com.digicert.tlm.plugin.model.PluginConfiguration;
import com.digicert.tlm.workflows.WorkflowExecutionException;
import com.digicert.tlm.workflows.automation.AbstractAutomationWorkflow;
import com.digicert.tlm.workflows.automation.dto.GenerateCsrRequest;
import com.digicert.tlm.workflows.automation.dto.GenerateCsrResponse;
import com.digicert.tlm.workflows.automation.dto.InstallCertificateRequest;
import com.digicert.tlm.workflows.automation.dto.InstallCertificateResponse;
import com.digicert.tlm.workflows.automation.dto.RefreshConfigurationRequest;
import com.digicert.tlm.workflows.automation.dto.RefreshConfigurationResponse;
import com.digicert.tlm.workflows.automation.dto.TestConnectionResponse;
import com.digicert.tlm.workflows.automation.dto.ValidateCertificateRequest;
import com.digicert.tlm.workflows.automation.dto.ValidateCertificateResponse;
import com.example.automation.adapter.AdapterConfig;
import com.example.automation.adapter.F5SshAdapter;
import com.example.automation.adapter.F5iControlRestAdapter;
import com.example.automation.extended.configuration.MyPluginConfiguration;
import com.example.automation.extended.request.MyGenerateCertificateRequest;
import com.example.automation.extended.request.MyInstallCertificateRequest;
import com.example.automation.extended.request.MyRefreshRequest;
import com.example.automation.extended.request.MyValidateRequest;
import com.example.automation.extended.response.MyRefreshResponse;
import com.example.automation.helper.CertificateAttributesUtil;
import com.example.automation.helper.F5AutomationPluginHelper;
import com.example.automation.model.F5ConfigurationData;
import com.fasterxml.jackson.databind.JsonNode;

import lombok.extern.slf4j.Slf4j;

/**
 * F5 BIG-IP automation plugin. The wiring is intentionally thin: the SDK invokes one of the five
 * lifecycle methods, the plugin reads the configuration, then delegates to a REST/SSH adapter
 * pair that runs Python scripts (bundled under {@code /ssh-scripts/}) against the device.
 */
@Slf4j
@WorkflowEntryPoint(name = "F5AutomationPlugin")
@SuppressWarnings("unchecked")
public class F5AutomationPlugin extends AbstractAutomationWorkflow {

    private static final String PLUGIN_NAME = "F5AutomationPlugin";

    private final MyPluginConfiguration extendedConfig;
    private final F5iControlRestAdapter restAdapter;
    private final F5SshAdapter sshAdapter;
    private final String managementIp;

    public F5AutomationPlugin(SdkContext context, PluginConfiguration<MyPluginConfiguration> configuration) {
        this.extendedConfig = Objects.requireNonNull(configuration.getExtendedConfig(),
                "Plugin extended configuration is required");
        log.info("Loaded extended configuration: host={}, port={}, user={}, updateServerSslProfile={} (raw '{}'), "
                        + "clientSslProfileMode={} (raw '{}')",
                extendedConfig.getManagementIp(),
                extendedConfig.getManagementPort(),
                extendedConfig.getUserName(),
                extendedConfig.isUpdateServerSslProfileEnabled(),
                extendedConfig.getUpdateServerSslProfile(),
                extendedConfig.isUpdateSameClientSslProfile() ? "update" : "create",
                extendedConfig.getClientSslProfileMode());

        this.managementIp = extendedConfig.getManagementIp();
        final var adapterConfig = AdapterConfig.builder()
                .host(extendedConfig.getManagementIp())
                .port(extendedConfig.getManagementPort())
                .username(extendedConfig.getUserName())
                .password(decodePassword(extendedConfig.getPassword()))
                .build();
        this.restAdapter = new F5iControlRestAdapter(adapterConfig);
        this.sshAdapter = new F5SshAdapter(adapterConfig);
    }

    /**
     * TLM hands plugin passwords over base64-encoded. The legacy F5 plugin decoded with
     * {@code Base64.getDecoder().decode(...)}, so we match that contract. If the value
     * doesn't decode cleanly (someone passed plain text), fall back to the original string
     * rather than failing hard.
     */
    private static String decodePassword(String raw) {
        if (raw == null || raw.isEmpty()) {
            return raw;
        }
        try {
            return new String(Base64.getDecoder().decode(raw), StandardCharsets.UTF_8);
        } catch (IllegalArgumentException e) {
            return raw;
        }
    }

    @Override
    public Response<JsonNode> testConnection(JsonNode request) throws WorkflowExecutionException {
        try {
            log.info("TestConnection request: {}", objectMapper.writeValueAsString(request));

            final var restResult = restAdapter.testConnection();
            final var sshResult = sshAdapter.testConnection();

            final TestConnectionResponse<JsonNode> response = new TestConnectionResponse<>();
            if (restResult.isSuccess() && sshResult.isSuccess()) {
                response.setActive(restResult.getValue().isActive() && sshResult.getValue().isActive());
            } else {
                final List<PluginError> errors = new ArrayList<>();
                if (!restResult.isSuccess()) {
                    errors.add(new PluginError(restResult.getErrorCode(), restResult.getErrorMessage()));
                }
                if (!sshResult.isSuccess()) {
                    errors.add(new PluginError(sshResult.getErrorCode(), sshResult.getErrorMessage()));
                }
                response.setErrors(errors);
                response.setActive(false);
            }

            log.info("TestConnection response: {}", objectMapper.writeValueAsString(response));
            return response;
        } catch (Exception e) {
            throw new WorkflowExecutionException("Error in testConnection: " + e.getMessage(), e);
        }
    }

    @Override
    public Response<JsonNode> generateCsr(JsonNode request) throws WorkflowExecutionException {
        try {
            log.info("GenerateCsr request: {}", objectMapper.writeValueAsString(request));

            final GenerateCsrRequest<MyGenerateCertificateRequest> csrRequest =
                    PluginUtils.convertWrappedObject(request, GenerateCsrRequest.class,
                            MyGenerateCertificateRequest.class);

            final var extended = Optional.ofNullable(csrRequest.getExtendedRequest())
                    .orElseGet(MyGenerateCertificateRequest::new);

            final var commonName = CertificateAttributesUtil.getCommonName(csrRequest.getSubjectDn());
            final var dnsNames = CertificateAttributesUtil.getDnsNames(csrRequest.getDnsNames());
            final var subjectDnFields = CertificateAttributesUtil.getSubjectDnFields(csrRequest.getSubjectDn());
            final var keyName = CertificateAttributesUtil.getObjectName(
                    commonName,
                    csrRequest.getFlowId(),
                    extended.getFlowStartDate(),
                    extended.getVirtualServerName());

            final var keyType = mapKeyType(csrRequest.getKeyAlgorithm());
            final var keySize = csrRequest.getKeySize();
            final var keyStorage = mapKeyStorage(extended.getKeyStorage());

            final var generated = sshAdapter.generateCsr(
                    extended.getVirtualServerName(),
                    commonName,
                    dnsNames,
                    keyName,
                    keySize,
                    keyType,
                    keyStorage,
                    subjectDnFields);

            final GenerateCsrResponse<JsonNode> response = new GenerateCsrResponse<>();
            if (generated.isSuccess()) {
                response.setCsr(generated.getValue().getCsr());

                // Persist a copy of the CSR locally so subsequent flow steps can reference it.
                final var pluginDir = Path.of(System.getProperty("java.io.tmpdir"), PLUGIN_NAME,
                        csrRequest.getFlowId());
                Files.createDirectories(pluginDir);
                Files.writeString(pluginDir.resolve("request.csr"), generated.getValue().getCsr());
            } else {
                response.setErrors(List.of(
                        new PluginError(generated.getErrorCode(), generated.getErrorMessage())));
            }

            log.info("GenerateCsr response: {}", objectMapper.writeValueAsString(response));
            return response;
        } catch (Exception e) {
            throw new WorkflowExecutionException("Error in generateCsr: " + e.getMessage(), e);
        }
    }

    @Override
    public Response<JsonNode> installCertificate(JsonNode request) throws WorkflowExecutionException {
        try {
            log.info("InstallCertificate request: {}", objectMapper.writeValueAsString(request));

            final InstallCertificateRequest<MyInstallCertificateRequest> installRequest =
                    PluginUtils.convertWrappedObject(request, InstallCertificateRequest.class,
                            MyInstallCertificateRequest.class);

            final var extended = Optional.ofNullable(installRequest.getExtendedRequest())
                    .orElseGet(MyInstallCertificateRequest::new);

            // Resolve the cert chain — prefer inline chain, otherwise download the artifact.
            Map<String, String> certificates;
            if (installRequest.getCertificateChain() != null
                    && !installRequest.getCertificateChain().isBlank()) {
                certificates = F5AutomationPluginHelper.splitChainPem(installRequest.getCertificateChain());
            } else if (installRequest.getCertificateLink() != null
                    && !installRequest.getCertificateLink().isBlank()) {
                final var pluginDir = Path.of(System.getProperty("java.io.tmpdir"), PLUGIN_NAME,
                        installRequest.getFlowId());
                Files.createDirectories(pluginDir);
                final var downloaded = F5AutomationPluginHelper.downloadFileToDirectory(
                        installRequest.getCertificateLink(), pluginDir.toString());
                certificates = F5AutomationPluginHelper.extractCertificatesFromZip(downloaded);
            } else {
                throw new WorkflowExecutionException(
                        "InstallCertificate request must include certificateChain or certificateLink",
                        new IllegalArgumentException("missing cert source"));
            }

            if (!certificates.containsKey("end_entity.cer")) {
                throw new WorkflowExecutionException(
                        "End-entity certificate not found in supplied artifact", null);
            }

            final var commonName = CertificateAttributesUtil.getCommonName(extended.getSubjectDn());
            final var keyName = CertificateAttributesUtil.getObjectName(
                    commonName,
                    installRequest.getFlowId(),
                    extended.getFlowStartDate(),
                    extended.getVirtualServerName());

            // The connector setting decides how the client-ssl profile is handled; TLM cannot set the
            // per-request flag for custom plugins, so it is logged for reference only.
            final var updateSameSslProfile = extendedConfig.isUpdateSameClientSslProfile();
            log.info("Client-ssl profile handling: {} (connector setting; TLM request flag updateSameSslProfile={})",
                    updateSameSslProfile ? "update existing profile" : "create new profile",
                    extended.getUpdateSameSslProfile());

            final var installResult = sshAdapter.installCertificate(
                    keyName,
                    extended.getVirtualServerName(),
                    certificates,
                    installRequest.getCurrentCertificateThumbprint(),
                    updateSameSslProfile,
                    extended.isUseCommonIca(),
                    extendedConfig.isUpdateServerSslProfileEnabled());

            final InstallCertificateResponse<JsonNode> response = new InstallCertificateResponse<>();
            if (!installResult.isSuccess()) {
                response.setErrors(List.of(
                        new PluginError(installResult.getErrorCode(), installResult.getErrorMessage())));
            }

            log.info("InstallCertificate response: {}", objectMapper.writeValueAsString(response));
            return response;
        } catch (WorkflowExecutionException e) {
            throw e;
        } catch (Exception e) {
            throw new WorkflowExecutionException("Error in installCertificate: " + e.getMessage(), e);
        }
    }

    @Override
    public Response<JsonNode> validateCertificate(JsonNode request) throws WorkflowExecutionException {
        try {
            log.info("ValidateCertificate request: {}", objectMapper.writeValueAsString(request));

            final ValidateCertificateRequest<MyValidateRequest> validateRequest =
                    PluginUtils.convertWrappedObject(request, ValidateCertificateRequest.class,
                            MyValidateRequest.class);
            final var extended = Optional.ofNullable(validateRequest.getExtendedRequest())
                    .orElseGet(MyValidateRequest::new);

            final var commonName = CertificateAttributesUtil.getCommonName(extended.getSubjectDn());
            final var keyName = CertificateAttributesUtil.getObjectName(
                    commonName,
                    validateRequest.getFlowId(),
                    extended.getFlowStartDate(),
                    extended.getVirtualServerName());

            final var validateResult = sshAdapter.validateCertificate(keyName, extended.getVirtualServerName());

            final ValidateCertificateResponse<JsonNode> response = new ValidateCertificateResponse<>();
            if (validateResult.isSuccess()) {
                response.setCertificate(validateResult.getValue().getCertificate());
            } else {
                response.setErrors(List.of(
                        new PluginError(validateResult.getErrorCode(), validateResult.getErrorMessage())));
            }

            log.info("ValidateCertificate response: {}", objectMapper.writeValueAsString(response));
            return response;
        } catch (Exception e) {
            throw new WorkflowExecutionException("Error in validateCertificate: " + e.getMessage(), e);
        }
    }

    @Override
    public Response<JsonNode> refreshConfiguration(JsonNode request) throws WorkflowExecutionException {
        try {
            final RefreshConfigurationRequest<MyRefreshRequest> refreshRequest =
                    PluginUtils.convertWrappedObject(request, RefreshConfigurationRequest.class,
                            MyRefreshRequest.class);
            log.info("RefreshConfiguration request: {}", objectMapper.writeValueAsString(refreshRequest));

            final var configResult = sshAdapter.getVirtualServersInfo();
            final RefreshConfigurationResponse<MyRefreshResponse> typedResponse =
                    new RefreshConfigurationResponse<>();

            if (configResult.isSuccess()) {
                populateRefreshResponse(typedResponse, configResult.getValue());
            }

            final RefreshConfigurationResponse<JsonNode> refreshResponse =
                    PluginUtils.convertWrappedObject(typedResponse, RefreshConfigurationResponse.class,
                            JsonNode.class);

            // Attach errors after the conversion: PluginError has no default constructor, so letting
            // convertWrappedObject round-trip it through Jackson fails and hides the real error.
            if (!configResult.isSuccess()) {
                log.error("RefreshConfiguration failed: {} ({})",
                        configResult.getErrorMessage(), configResult.getErrorCode());
                refreshResponse.setErrors(List.of(
                        new PluginError(configResult.getErrorCode(), configResult.getErrorMessage())));
            }

            log.info("RefreshConfiguration response: {}", objectMapper.writeValueAsString(refreshResponse));
            return refreshResponse;
        } catch (Exception e) {
            throw new WorkflowExecutionException("Error in refreshConfiguration: " + e.getMessage(), e);
        }
    }

    private void populateRefreshResponse(RefreshConfigurationResponse<MyRefreshResponse> response,
                                         F5ConfigurationData data) {
        final var systemInfo = Optional.ofNullable(data.getSystemVersionDetails())
                .orElseGet(F5ConfigurationData.SystemVersionDetails::new);
        final var virtualServers = Optional.ofNullable(data.getVirtualServers()).orElseGet(List::of);
        final var certificates = Optional.ofNullable(data.getCertificates()).orElseGet(List::of);
        final var peers = Optional.ofNullable(data.getPeers()).orElseGet(List::of);
        final var partitions = Optional.ofNullable(data.getPartitions()).orElseGet(List::of);

        final var automationInfo = new RefreshConfigurationResponse.AutomationInfo();
        automationInfo.setManagementIp(managementIp);
        automationInfo.setHostName(systemInfo.getHostname());
        automationInfo.setOsName(F5ConfigurationData.SystemVersionDetails.BIGIP);
        automationInfo.setOsFlavor(systemInfo.getProduct());
        automationInfo.setOsVersion(systemInfo.getVersion());
        automationInfo.setDataIps(virtualServers.stream()
                .map(F5ConfigurationData.VirtualServer::getIp)
                .filter(Objects::nonNull)
                .distinct()
                .toArray(String[]::new));
        automationInfo.setPeerInfo(peers.stream()
                .map(p -> String.format("%s:%s",
                        p.getManagementIp(),
                        p.getFailoverState() == null ? "" : p.getFailoverState().toUpperCase()))
                .collect(Collectors.joining(",")));
        automationInfo.setPartitions(partitions.toArray(String[]::new));
        response.setAutomationInfo(automationInfo);

        response.setDataIpInfo(virtualServers.stream()
                .map(vs -> {
                    try {
                        final var info = new RefreshConfigurationResponse.DataIpInfo();
                        info.setManagementIp(managementIp);
                        info.setDataIp(vs.getIp());
                        info.setPort(vs.getPort() == null ? null : Integer.parseInt(vs.getPort()));
                        info.setPartition(vs.getPartition() == null ? null : "/" + vs.getPartition());
                        info.setAlias(vs.getVirtualServerName());
                        info.setSslState(vs.getSslState());
                        return info;
                    } catch (Exception ex) {
                        log.error("Failed to map virtual server {}", vs, ex);
                        return null;
                    }
                })
                .filter(Objects::nonNull)
                .toList());

        response.setCertificates(certificates.stream()
                .map(c -> {
                    final var cert = new RefreshConfigurationResponse.Certificate();
                    cert.setIpAddress(c.getIp());
                    cert.setPort(c.getPort() == null ? null : Integer.parseInt(c.getPort()));
                    cert.setIpAndPort(c.getDestination());
                    cert.setCertificate(c.getCert());
                    cert.setSni(c.isSni());
                    cert.setCipherDiscovery(c.getCipherDiscovery());
                    return cert;
                })
                .toList());
    }

    private static String mapKeyType(String keyAlgorithm) {
        if (keyAlgorithm == null) {
            return "rsa-private";
        }
        return keyAlgorithm.toLowerCase().startsWith("rsa") ? "rsa-private" : "ec-private";
    }

    private static F5SshAdapter.KeyStorage mapKeyStorage(String keyStorage) {
        if (keyStorage == null) {
            return F5SshAdapter.KeyStorage.NORMAL;
        }
        return switch (keyStorage.toLowerCase()) {
            case "fips" -> F5SshAdapter.KeyStorage.FIPS;
            case "nethsm", "net_hsm", "hsm" -> F5SshAdapter.KeyStorage.NET_HSM;
            default -> F5SshAdapter.KeyStorage.NORMAL;
        };
    }
}
