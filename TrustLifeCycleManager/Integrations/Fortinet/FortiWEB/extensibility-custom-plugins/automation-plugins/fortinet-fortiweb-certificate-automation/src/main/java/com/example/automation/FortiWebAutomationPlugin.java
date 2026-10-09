package com.example.automation;

import java.nio.ByteBuffer;
import java.nio.charset.CharacterCodingException;
import java.nio.charset.CodingErrorAction;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.time.OffsetDateTime;
import java.util.ArrayList;
import java.util.Base64;
import java.util.List;
import java.util.Map;
import java.util.Objects;
import java.util.Optional;

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
import com.example.automation.adapter.FortiWebAdapter;
import com.example.automation.extended.configuration.MyPluginConfiguration;
import com.example.automation.extended.request.MyGenerateCertificateRequest;
import com.example.automation.extended.request.MyInstallCertificateRequest;
import com.example.automation.extended.request.MyRefreshRequest;
import com.example.automation.extended.request.MyValidateRequest;
import com.example.automation.extended.response.MyRefreshResponse;
import com.example.automation.helper.CertificateAttributesUtil;
import com.example.automation.helper.FortiWebAutomationPluginHelper;
import com.example.automation.helper.ReplacementResolver;
import com.example.automation.model.FlowRecord;
import com.example.automation.model.FortiWebCertificate;
import com.example.automation.model.FortiWebConfigurationData;
import com.fasterxml.jackson.databind.JsonNode;

import lombok.extern.slf4j.Slf4j;

/**
 * Fortinet FortiWeb automation plugin for DigiCert Trust Lifecycle Manager. The SDK invokes one of
 * the five lifecycle methods; the plugin reads its configuration and delegates to a single
 * {@link FortiWebAdapter} that drives one appliance over the FortiWeb REST API:
 * <ul>
 *   <li>{@code refreshConfiguration} → list local certificates + scan policies / SNI / multi-cert
 *       groups for references (asset discovery)</li>
 *   <li>{@code generateCsr} → key pair + PKCS#10 CSR generated <em>on the sensor</em>; the private
 *       key is retained under the flow directory</li>
 *   <li>{@code installCertificate} → multipart import of certificate + key under a unique name,
 *       repoint every reference of the replaced certificate, delete the replaced certificate</li>
 *   <li>{@code validateCertificate} → confirm the new certificate is listed with status OK</li>
 * </ul>
 *
 * <p><b>Replace-in-place use case.</b> A FortiWeb appliance typically ships with a self-signed local
 * certificate bound to (or waiting to be bound to) a server policy. Discovery surfaces every local
 * certificate as a selectable asset; when the operator selects one and TLM issues a certificate for
 * it, the asset's FortiWeb name is round-tripped in {@code virtualServerName} and the install
 * rotates it out: the new certificate takes over every reference and the old one is deleted.
 */
@Slf4j
@WorkflowEntryPoint(name = "FortiWebAutomationPlugin")
@SuppressWarnings("unchecked")
public class FortiWebAutomationPlugin extends AbstractAutomationWorkflow {

    private static final String PLUGIN_NAME = FortiWebAutomationPluginHelper.PLUGIN_NAME;

    /** Port used for the synthetic per-certificate endpoint in discovery. */
    private static final Integer ENDPOINT_PORT = 443;

    private final MyPluginConfiguration extendedConfig;
    /** Null when the connector configuration is unusable; see {@link #configurationError}. */
    private final FortiWebAdapter adapter;
    private final String configurationError;
    private final String host;
    private final int port;
    private final boolean keepReplaced;

    public FortiWebAutomationPlugin(SdkContext context,
            PluginConfiguration<MyPluginConfiguration> configuration) {
        this.extendedConfig = Objects.requireNonNull(configuration.getExtendedConfig(),
                "Plugin extended configuration is required");
        final var secretsManager = extendedConfig.isSecretsManagerAuth();
        this.host = AdapterConfig.normalizeHost(extendedConfig.getHost());
        this.port = FortiWebAutomationPluginHelper.parseIntOrDefault(extendedConfig.getPort(), AdapterConfig.DEFAULT_PORT);
        this.keepReplaced = Boolean.TRUE.equals(extendedConfig.getKeepReplacedCertificate());
        final Integer sshPort = resolveSshPort(extendedConfig.getSshPort());
        log.info("Loaded extended configuration: host={} (raw '{}'), port={}, sshPort={} (raw '{}'), username={}, vdom={}, "
                + "authenticationMethod={}, pamConnectorId={}, keepReplacedCertificate={}",
                host, extendedConfig.getHost(), port, sshPort == null ? "disabled" : sshPort, extendedConfig.getSshPort(),
                extendedConfig.getUsername(),
                Optional.ofNullable(extendedConfig.getVdom()).filter(v -> !v.isBlank()).orElse(AdapterConfig.DEFAULT_VDOM),
                secretsManager ? "secrets-manager" : "direct-input",
                secretsManager ? extendedConfig.getPamConnectorId() : "n/a", keepReplaced);

        // Fail closed: never build an API token around a missing password. In secrets-manager mode
        // an empty value means the PAM connector could not resolve the vault reference.
        final var password = decodeSecret(extendedConfig.getPassword());
        if (host == null) {
            this.configurationError = "FortiWeb host is empty. Enter the appliance FQDN or IP on the connector.";
        } else if (extendedConfig.getUsername() == null || extendedConfig.getUsername().isBlank()) {
            this.configurationError = "FortiWeb username is empty. Enter the API administrator account on the connector.";
        } else if (password == null || password.isBlank()) {
            this.configurationError = secretsManager
                    ? "FortiWeb password was not resolved by the Secrets Manager (PAM) connector"
                            + (extendedConfig.getPamConnectorId() == null
                                    ? "" : " '" + extendedConfig.getPamConnectorId() + "'")
                            + ". Check the PAM connector's Test Connection and that the vault reference"
                            + " points at an existing secret the connector is allowed to read."
                    : "FortiWeb password is empty. Re-enter it on the connector, or if the connector"
                            + " uses Self-authentication (Secrets manager), check that the PAM connector"
                            + " resolved the vault reference.";
        } else {
            this.configurationError = null;
        }
        if (configurationError != null) {
            log.error(configurationError);
            this.adapter = null;
            return;
        }
        log.info("FortiWeb password received ({} characters, redacted)", password.length());

        this.adapter = new FortiWebAdapter(AdapterConfig.builder()
                .host(host)
                .port(port)
                .username(extendedConfig.getUsername().trim())
                .password(password)
                .vdom(extendedConfig.getVdom())
                .sshPort(sshPort)
                .keepReplacedCertificate(keepReplaced)
                .build());
    }

    /**
     * SSH port resolution. Absent/blank → {@value AdapterConfig#DEFAULT_SSH_PORT} (SSH on): a
     * connector created before the field existed, or saved without touching it, may not deliver the
     * field at all, and without SSH discovery cannot hand TLM any certificate body. {@code 0},
     * {@code off}, {@code none} or {@code disable} switch SSH off explicitly.
     */
    static Integer resolveSshPort(String raw) {
        if (raw == null || raw.isBlank()) {
            return AdapterConfig.DEFAULT_SSH_PORT;
        }
        final var value = raw.trim().toLowerCase();
        if (value.equals("0") || value.equals("off") || value.equals("none") || value.equals("disable")
                || value.equals("disabled") || value.equals("false")) {
            return null;
        }
        final int port = FortiWebAutomationPluginHelper.parseIntOrDefault(value, -1);
        if (port <= 0 || port > 65535) {
            log.warn("SSH port '{}' is not a valid port - using {}", raw, AdapterConfig.DEFAULT_SSH_PORT);
            return AdapterConfig.DEFAULT_SSH_PORT;
        }
        return port;
    }

    /**
     * TLM hands directly-entered plugin secrets over base64-encoded, while a secret injected by a
     * Secrets Manager (PAM) connector may arrive as plain text. Decode when the value is valid
     * base64 <em>and</em> the decoded bytes are printable text; otherwise use the value as-is.
     */
    static String decodeSecret(String raw) {
        if (raw == null || raw.isEmpty()) {
            return raw;
        }
        final byte[] decoded;
        try {
            decoded = Base64.getDecoder().decode(raw.trim());
        } catch (IllegalArgumentException e) {
            return raw;
        }
        final var text = decodeUtf8Text(decoded);
        return text != null ? text : raw;
    }

    private static String decodeUtf8Text(byte[] bytes) {
        try {
            final var text = StandardCharsets.UTF_8.newDecoder()
                    .onMalformedInput(CodingErrorAction.REPORT)
                    .onUnmappableCharacter(CodingErrorAction.REPORT)
                    .decode(ByteBuffer.wrap(bytes))
                    .toString();
            if (text.isEmpty()) {
                return null;
            }
            for (int i = 0; i < text.length(); i++) {
                final char c = text.charAt(i);
                if (Character.isISOControl(c) && c != '\n' && c != '\r' && c != '\t') {
                    return null;
                }
            }
            return text;
        } catch (CharacterCodingException e) {
            return null;
        }
    }

    private void requireUsableConfiguration() throws WorkflowExecutionException {
        if (adapter == null) {
            throw new WorkflowExecutionException(configurationError,
                    new IllegalStateException(configurationError));
        }
    }

    // ------------------------------------------------------------------ testConnection

    @Override
    public Response<JsonNode> testConnection(JsonNode request) throws WorkflowExecutionException {
        requireUsableConfiguration();
        try {
            log.info("TestConnection request: {}", objectMapper.writeValueAsString(request));
            final var result = adapter.testConnection();

            final TestConnectionResponse<JsonNode> response = new TestConnectionResponse<>();
            if (result.isSuccess()) {
                response.setActive(result.getValue().isActive());
            } else {
                response.setActive(false);
                response.setErrors(List.of(new PluginError(result.getErrorCode(), result.getErrorMessage())));
            }
            log.info("TestConnection response: {}", objectMapper.writeValueAsString(response));
            return response;
        } catch (Exception e) {
            throw new WorkflowExecutionException("Error in testConnection: " + e.getMessage(), e);
        }
    }

    // ------------------------------------------------------------------ generateCsr

    @Override
    public Response<JsonNode> generateCsr(JsonNode request) throws WorkflowExecutionException {
        requireUsableConfiguration();
        try {
            log.info("GenerateCsr request: {}", objectMapper.writeValueAsString(request));

            final GenerateCsrRequest<MyGenerateCertificateRequest> csrRequest =
                    PluginUtils.convertWrappedObject(request, GenerateCsrRequest.class,
                            MyGenerateCertificateRequest.class);
            final var extended = Optional.ofNullable(csrRequest.getExtendedRequest())
                    .orElseGet(MyGenerateCertificateRequest::new);

            final GenerateCsrResponse<JsonNode> response = new GenerateCsrResponse<>();
            if (csrRequest.getSubjectDn() == null || csrRequest.getSubjectDn().isBlank()) {
                response.setErrors(List.of(new PluginError("CSR_GENERATION_ERROR",
                        "A subject DN is required to generate the CSR")));
                return response;
            }
            final var replaced = resolveReplacedCertificateName(extended.getCertificateName(),
                    extended.getVirtualServerName());
            log.info("Generating CSR for flow {} (subject [{}], SANs [{}], key {}/{}, sig {}); will replace "
                    + "FortiWeb certificate '{}' at install time",
                    csrRequest.getFlowId(), csrRequest.getSubjectDn(), csrRequest.getDnsNames(),
                    csrRequest.getKeyAlgorithm(), csrRequest.getKeySize(), csrRequest.getSignatureAlgorithm(),
                    replaced == null ? "<none - new certificate>" : replaced);

            final var csr = FortiWebAutomationPluginHelper.generateCsrAndStoreKey(
                    csrRequest.getFlowId(),
                    csrRequest.getSubjectDn(),
                    CertificateAttributesUtil.getDnsNames(csrRequest.getDnsNames()),
                    csrRequest.getKeyAlgorithm(),
                    csrRequest.getKeySize(),
                    csrRequest.getSignatureAlgorithm());
            response.setCsr(csr);
            log.info("GenerateCsr response: {}", objectMapper.writeValueAsString(response));
            return response;
        } catch (Exception e) {
            throw new WorkflowExecutionException("Error in generateCsr: " + e.getMessage(), e);
        }
    }

    // ------------------------------------------------------------------ installCertificate

    @Override
    public Response<JsonNode> installCertificate(JsonNode request) throws WorkflowExecutionException {
        requireUsableConfiguration();
        try {
            log.info("InstallCertificate request: {}", objectMapper.writeValueAsString(request));

            final InstallCertificateRequest<MyInstallCertificateRequest> installRequest =
                    PluginUtils.convertWrappedObject(request, InstallCertificateRequest.class,
                            MyInstallCertificateRequest.class);
            final var extended = Optional.ofNullable(installRequest.getExtendedRequest())
                    .orElseGet(MyInstallCertificateRequest::new);
            final var flowId = installRequest.getFlowId();

            // Resolve the cert chain — prefer inline chain, otherwise download the artifact.
            final Map<String, String> certificates;
            if (installRequest.getCertificateChain() != null && !installRequest.getCertificateChain().isBlank()) {
                certificates = FortiWebAutomationPluginHelper.splitChainPem(installRequest.getCertificateChain());
            } else if (installRequest.getCertificateLink() != null && !installRequest.getCertificateLink().isBlank()) {
                final Path pluginDir = FortiWebAutomationPluginHelper.flowDirectory(flowId);
                Files.createDirectories(pluginDir);
                final var downloaded = FortiWebAutomationPluginHelper.downloadFileToDirectory(
                        installRequest.getCertificateLink(), pluginDir.toString());
                certificates = FortiWebAutomationPluginHelper.extractCertificates(downloaded);
                Files.deleteIfExists(downloaded);
            } else {
                throw new WorkflowExecutionException(
                        "InstallCertificate request must include certificateChain or certificateLink",
                        new IllegalArgumentException("missing cert source"));
            }
            final var leafPem = certificates.get("end_entity.cer");
            if (leafPem == null) {
                throw new WorkflowExecutionException("End-entity certificate not found in supplied artifact", null);
            }
            final var leaf = FortiWebAutomationPluginHelper.parseFirstCertificate(leafPem);
            final var leafCn = CertificateAttributesUtil.getCommonName(leaf.getSubjectX500Principal().getName());
            final var leafSerial = CertificateAttributesUtil.serialHex(leaf);

            // The private key generated on this sensor during generateCsr.
            final var keyPem = FortiWebAutomationPluginHelper.readStoredPrivateKey(flowId);

            // Certificate file: leaf first; append the ICA when requested (FortiWeb reads the first
            // block as the local certificate and configures intermediates separately).
            final var certFile = new StringBuilder(FortiWebAutomationPluginHelper.normalizePem(leafPem));
            final var ica = certificates.get("ica.cer");
            if (extended.isUseCommonIca() && ica != null && !ica.isBlank()) {
                certFile.append(FortiWebAutomationPluginHelper.normalizePem(ica));
            }

            // Which FortiWeb certificate is being replaced? The alias TLM round-trips can be stale
            // (it keeps the first-discovered alias while every renewal creates a new FortiWeb name),
            // so resolve through alias -> thumbprint -> endpoint -> subject, accepting only names
            // that exist on the appliance.
            final var newName = CertificateAttributesUtil.buildUniqueName(leafCn, leafSerial, "tlm_cert");
            final var currentCerts = adapter.listCertificates();
            final var selection = ReplacementResolver.resolve(
                    currentCerts,
                    adapter.fetchCliCertificatePems(),
                    assignEndpoints(currentCerts, host),
                    extended.getCertificateName(),
                    extended.getVirtualServerName(),
                    installRequest.getCurrentCertificateThumbprint(),
                    firstNonBlank(extended.getIpAddress(), text(request, "ipAddress")),
                    leaf,
                    newName);
            final var replacedNames = selection.names();
            log.info("Installing certificate '{}' (CN {}, serial {}) on {}; replacing {} - selected by: {}", newName,
                    leafCn, leafSerial, host, replacedNames.isEmpty() ? "<nothing - initial import>" : replacedNames,
                    selection.strategy());
            if (replacedNames.isEmpty() && (extended.getVirtualServerName() != null
                    || installRequest.getCurrentCertificateThumbprint() != null)) {
                log.warn("TLM asked to replace an existing certificate (alias '{}', thumbprint {}) but none of the "
                        + "certificates on FortiWeb {} could be identified as it - the new certificate will be imported "
                        + "without repointing or deleting anything", extended.getVirtualServerName(),
                        installRequest.getCurrentCertificateThumbprint(),
                        currentCerts.stream().map(FortiWebCertificate::getName).toList());
            }

            final var installResult = adapter.installCertificate(newName, certFile.toString(), keyPem, leaf,
                    replacedNames, keepReplaced);

            final InstallCertificateResponse<JsonNode> response = new InstallCertificateResponse<>();
            if (installResult.isSuccess()) {
                final var installed = installResult.getValue();
                // Persist what validateCertificate needs (fresh JVM per call), then drop the key.
                final var record = new FlowRecord();
                record.setInstalledCertificateName(installed.getCertificateName());
                record.setInstalledCertificatePem(FortiWebAutomationPluginHelper.normalizePem(leafPem));
                record.setInstalledSerialNumber(leafSerial);
                record.setReplacedCertificateNames(replacedNames);
                record.setInstalledAt(OffsetDateTime.now().toString());
                FortiWebAutomationPluginHelper.writeFlowRecord(flowId, record);
                FortiWebAutomationPluginHelper.deleteStoredPrivateKey(flowId);
                log.info("Install complete: name='{}', repointed={}, deleted={}, retained={}",
                        installed.getCertificateName(), installed.getReferencesRepointed(),
                        installed.getDeletedCertificates(), installed.getRetainedCertificates());
            } else {
                response.setErrors(List.of(new PluginError(installResult.getErrorCode(), installResult.getErrorMessage())));
            }
            log.info("InstallCertificate response: {}", objectMapper.writeValueAsString(response));
            return response;
        } catch (WorkflowExecutionException e) {
            throw e;
        } catch (Exception e) {
            throw new WorkflowExecutionException("Error in installCertificate: " + e.getMessage(), e);
        }
    }

    // ------------------------------------------------------------------ validateCertificate

    @Override
    public Response<JsonNode> validateCertificate(JsonNode request) throws WorkflowExecutionException {
        requireUsableConfiguration();
        try {
            log.info("ValidateCertificate request: {}", objectMapper.writeValueAsString(request));

            final ValidateCertificateRequest<MyValidateRequest> validateRequest =
                    PluginUtils.convertWrappedObject(request, ValidateCertificateRequest.class, MyValidateRequest.class);
            final var extended = Optional.ofNullable(validateRequest.getExtendedRequest()).orElseGet(MyValidateRequest::new);
            final var flowId = validateRequest.getFlowId();

            // Primary source of truth: the record written by installCertificate for this flow.
            final FlowRecord record = FortiWebAutomationPluginHelper.readFlowRecord(flowId);
            String name = record == null ? null : record.getInstalledCertificateName();
            String expectedSerial = record == null ? null : record.getInstalledSerialNumber();
            if (expectedSerial == null || expectedSerial.isBlank()) {
                expectedSerial = firstNonBlank(extended.getCertificateSerialNumber(), text(request, "certificateSerialNumber"));
            }
            if (name == null || name.isBlank()) {
                name = firstNonBlank(extended.getCertificateName(), stripPartition(extended.getVirtualServerName()));
            }
            if ((name == null || name.isBlank()) && expectedSerial != null) {
                // No record and no name: find the certificate by serial in the FortiWeb list.
                final var serial = expectedSerial;
                name = adapter.listCertificates().stream()
                        .filter(c -> CertificateAttributesUtil.sameSerial(c.getSerialNumber(), serial))
                        .map(FortiWebCertificate::getName).findFirst().orElse(null);
            }
            final ValidateCertificateResponse<JsonNode> response = new ValidateCertificateResponse<>();
            if (name == null || name.isBlank()) {
                response.setErrors(List.of(new PluginError("CERTIFICATE_VALIDATION_ERROR",
                        "Cannot determine which FortiWeb certificate to validate: no flow record for flow '" + flowId
                                + "' and no certificateName / virtualServerName / serial in the request")));
                return response;
            }

            final var result = adapter.validateCertificate(name, expectedSerial);
            if (result.isSuccess()) {
                final var entry = result.getValue();
                var pem = record == null ? null : record.getInstalledCertificatePem();
                if (pem == null || pem.isBlank()) {
                    pem = entry.getCertificatePem();
                }
                if (pem == null) {
                    log.warn("Certificate '{}' validated on FortiWeb but its PEM is not available to return", name);
                }
                response.setCertificate(pem);
            } else {
                response.setErrors(List.of(new PluginError(result.getErrorCode(), result.getErrorMessage())));
            }
            log.info("ValidateCertificate response: {}", objectMapper.writeValueAsString(response));
            return response;
        } catch (Exception e) {
            throw new WorkflowExecutionException("Error in validateCertificate: " + e.getMessage(), e);
        }
    }

    // ------------------------------------------------------------------ refreshConfiguration

    @Override
    public Response<JsonNode> refreshConfiguration(JsonNode request) throws WorkflowExecutionException {
        requireUsableConfiguration();
        try {
            final RefreshConfigurationRequest<MyRefreshRequest> refreshRequest =
                    PluginUtils.convertWrappedObject(request, RefreshConfigurationRequest.class, MyRefreshRequest.class);
            log.info("RefreshConfiguration request: {}", objectMapper.writeValueAsString(refreshRequest));

            final var configResult = adapter.getConfigurationData();
            if (!configResult.isSuccess()) {
                // Return the error response directly: PluginError has no default constructor, so
                // round-tripping it through PluginUtils.convertWrappedObject would fail.
                final RefreshConfigurationResponse<JsonNode> errorResponse = new RefreshConfigurationResponse<>();
                errorResponse.setErrors(List.of(new PluginError(configResult.getErrorCode(), configResult.getErrorMessage())));
                log.info("RefreshConfiguration response (error): {}", objectMapper.writeValueAsString(errorResponse));
                return errorResponse;
            }

            final RefreshConfigurationResponse<MyRefreshResponse> typedResponse = new RefreshConfigurationResponse<>();
            populateRefreshResponse(typedResponse, configResult.getValue());

            final RefreshConfigurationResponse<JsonNode> refreshResponse =
                    PluginUtils.convertWrappedObject(typedResponse, RefreshConfigurationResponse.class, JsonNode.class);
            log.info("RefreshConfiguration response: {}", objectMapper.writeValueAsString(refreshResponse));
            return refreshResponse;
        } catch (Exception e) {
            throw new WorkflowExecutionException("Error in refreshConfiguration: " + e.getMessage(), e);
        }
    }

    private void populateRefreshResponse(RefreshConfigurationResponse<MyRefreshResponse> response,
                                         FortiWebConfigurationData data) {
        final var certificates = Optional.ofNullable(data.getCertificates()).orElseGet(List::of);

        // TLM's automation inventory is endpoint-centric and keys endpoints by dataIp:port. FortiWeb
        // certificates may be bound to a policy VIP, several may share one VIP (SNI), or - like a
        // factory self-signed cert - be bound to nothing at all. So each certificate gets its own
        // synthetic endpoint. Because every renewal imports the certificate under a NEW FortiWeb
        // name (FortiWeb cannot overwrite), the endpoint is derived from what survives a renewal -
        // the subject CN and the key algorithm: <cn>-<rsa|ecc>.<fortiwebHost>:443. TLM therefore
        // sees ONE endpoint across renewals, while the alias carries the current FortiWeb name so
        // the install knows exactly which certificate to rotate out. See assignEndpoints for how
        // same-CN/same-algorithm duplicates are kept apart.
        final Map<String, String> endpoints = assignEndpoints(certificates);

        final var automationInfo = new RefreshConfigurationResponse.AutomationInfo();
        automationInfo.setManagementIp(host);
        automationInfo.setHostName(host);
        automationInfo.setOsName(FortiWebConfigurationData.OS_NAME);
        automationInfo.setOsFlavor("Fortinet FortiWeb");
        automationInfo.setDataIps(certificates.stream().map(c -> endpoints.get(c.getName())).toArray(String[]::new));
        response.setAutomationInfo(automationInfo);

        response.setDataIpInfo(certificates.stream()
                .map(c -> {
                    final var info = new RefreshConfigurationResponse.DataIpInfo();
                    info.setManagementIp(host);
                    info.setDataIp(endpoints.get(c.getName()));
                    info.setPort(ENDPOINT_PORT);
                    info.setAlias(c.getName());
                    info.setSslState(1);
                    return info;
                })
                .toList());

        response.setCertificates(certificates.stream()
                .map(c -> {
                    final var cert = new RefreshConfigurationResponse.Certificate();
                    final var endpoint = endpoints.get(c.getName());
                    cert.setIpAddress(endpoint);
                    cert.setPort(ENDPOINT_PORT);
                    cert.setIpAndPort(endpoint + ":" + ENDPOINT_PORT);
                    // CN when known, else the FortiWeb name, so the asset is always identifiable.
                    cert.setDomainName(c.getCommonName() != null ? c.getCommonName() : c.getName());
                    // PEM only when it could be fetched; FortiWeb's list never carries the body.
                    cert.setCertificate(c.getCertificatePem());
                    cert.setServerParam(c.getName());
                    cert.setSni(data.referencesOf(c.getName()).stream()
                            .anyMatch(r -> r.getType() == com.example.automation.model.CertificateReference.Type.SNI_MEMBER));
                    return cert;
                })
                .toList());
    }

    // ------------------------------------------------------------------ name resolution

    /**
     * The FortiWeb certificate a CSR request intends to replace (informational at this stage): an
     * explicit {@code certificateName} override, else the alias round-tripped in
     * {@code virtualServerName}, else null. The install resolves the real target via
     * {@link ReplacementResolver}, which also copes with a stale alias.
     */
    private static String resolveReplacedCertificateName(String explicit, String virtualServerName) {
        if (explicit != null && !explicit.isBlank()) {
            return explicit.trim();
        }
        return ReplacementResolver.stripPartition(virtualServerName);
    }

    /** See {@link ReplacementResolver#stripPartition(String)}. */
    private static String stripPartition(String virtualServerName) {
        return ReplacementResolver.stripPartition(virtualServerName);
    }

    /**
     * Assigns each certificate its discovery endpoint host (certificate name → host).
     *
     * <p>The canonical host is {@code <sanitised CN>-<key type>.<fortiwebHost>}, e.g.
     * {@code tlsguru-com-rsa.fwb.example.com}. It does not contain the FortiWeb object name, so it
     * stays the same when a renewal imports the certificate under a new name — TLM keeps tracking a
     * single endpoint. When several certificates share CN and key type (e.g. the previous certificate
     * was kept after a rotation, or duplicates were uploaded by hand), the one expiring last owns the
     * canonical host and the others fall back to {@code <name>.<fortiwebHost>} so nothing collapses
     * onto one endpoint. A certificate without a readable CN also uses the name-based host.
     */
    private Map<String, String> assignEndpoints(List<FortiWebCertificate> certificates) {
        return assignEndpoints(certificates, host);
    }

    static Map<String, String> assignEndpoints(List<FortiWebCertificate> certificates, String host) {
        final Map<String, String> result = new java.util.LinkedHashMap<>();
        final Map<String, List<FortiWebCertificate>> byCanonical = new java.util.LinkedHashMap<>();
        for (FortiWebCertificate c : certificates) {
            final var canonical = canonicalEndpointHost(c, host);
            if (canonical == null) {
                result.put(c.getName(), nameEndpointHost(c.getName(), host));
            } else {
                byCanonical.computeIfAbsent(canonical, k -> new ArrayList<>()).add(c);
            }
        }
        for (var entry : byCanonical.entrySet()) {
            final var group = entry.getValue();
            // Newest (latest validTo) owns the stable endpoint; FortiWeb prints validTo as
            // "yyyy-MM-dd HH:mm:ss  GMT", so the string order is the chronological order.
            group.sort((a, b) -> Objects.requireNonNullElse(b.getValidTo(), "")
                    .compareTo(Objects.requireNonNullElse(a.getValidTo(), "")));
            for (int i = 0; i < group.size(); i++) {
                final var c = group.get(i);
                if (i == 0) {
                    result.put(c.getName(), entry.getKey());
                } else {
                    result.put(c.getName(), nameEndpointHost(c.getName(), host));
                    log.info("Certificate '{}' shares CN/key type with '{}' - reported on endpoint {} instead of {}",
                            c.getName(), group.get(0).getName(), nameEndpointHost(c.getName(), host), entry.getKey());
                }
            }
        }
        result.forEach((name, ep) -> log.info("Endpoint for certificate '{}': {}:{}", name, ep, ENDPOINT_PORT));
        return result;
    }

    /** {@code <sanitised CN>-<rsa|ecc|dsa|kN>.<fortiwebHost>}, or null when the CN is unknown. */
    private static String canonicalEndpointHost(FortiWebCertificate c, String host) {
        final var cn = c.getCommonName();
        if (cn == null || cn.isBlank()) {
            return null;
        }
        final var label = dnsLabel(cn) + "-" + keyTypeLabel(c.getPkeyType());
        return label + "." + host;
    }

    /** {@code <sanitised name>.<fortiwebHost>} — the fallback that is unique per FortiWeb object. */
    private static String nameEndpointHost(String certName, String host) {
        if (certName == null || certName.isBlank()) {
            return host;
        }
        return dnsLabel(certName) + "." + host;
    }

    /** FortiWeb pkey_type → short algorithm label (observed on 8.0.5: RSA = 1, ECDSA = 3). */
    static String keyTypeLabel(Integer pkeyType) {
        if (pkeyType == null) {
            return "key";
        }
        return switch (pkeyType) {
            case 1 -> "rsa";
            case 2 -> "dsa";
            case 3 -> "ecc";
            default -> "k" + pkeyType;
        };
    }

    /** Lower-case DNS-label-safe form of a value: {@code [a-z0-9-]}, collapsed and trimmed, non-empty. */
    static String dnsLabel(String value) {
        var label = value.toLowerCase().replaceAll("[^a-z0-9-]", "-").replaceAll("-{2,}", "-")
                .replaceAll("^-+", "").replaceAll("-+$", "");
        if (label.isEmpty()) {
            label = "cert";
        }
        return label.length() > 63 ? label.substring(0, 63).replaceAll("-+$", "") : label;
    }

    private static String text(JsonNode node, String field) {
        if (node == null) {
            return null;
        }
        final var v = node.get(field);
        return v == null || v.isNull() ? null : v.asText();
    }

    private static String firstNonBlank(String... values) {
        for (String v : values) {
            if (v != null && !v.isBlank()) {
                return v.trim();
            }
        }
        return null;
    }
}
