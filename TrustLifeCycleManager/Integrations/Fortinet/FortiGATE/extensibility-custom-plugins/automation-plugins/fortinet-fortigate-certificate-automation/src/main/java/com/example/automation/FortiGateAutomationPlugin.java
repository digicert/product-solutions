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
import com.example.automation.adapter.FortiGateAdapter;
import com.example.automation.extended.configuration.MyPluginConfiguration;
import com.example.automation.extended.request.MyGenerateCertificateRequest;
import com.example.automation.extended.request.MyInstallCertificateRequest;
import com.example.automation.extended.request.MyRefreshRequest;
import com.example.automation.extended.request.MyValidateRequest;
import com.example.automation.extended.response.MyRefreshResponse;
import com.example.automation.helper.CertificateAttributesUtil;
import com.example.automation.helper.FortiGateAutomationPluginHelper;
import com.example.automation.helper.ReplacementResolver;
import com.example.automation.model.CertificateReference;
import com.example.automation.model.FlowRecord;
import com.example.automation.model.FortiGateCertificate;
import com.example.automation.model.FortiGateConfigurationData;
import com.fasterxml.jackson.databind.JsonNode;

import lombok.extern.slf4j.Slf4j;

/**
 * Fortinet FortiGate automation plugin for DigiCert Trust Lifecycle Manager. The SDK invokes one of
 * the five lifecycle methods; the plugin reads its configuration and delegates to a single
 * {@link FortiGateAdapter} that drives one appliance over the FortiOS REST API:
 * <ul>
 *   <li>{@code refreshConfiguration} → list local certificates + scan SSL-VPN / admin HTTPS / IPsec /
 *       VIP / SSL-inspection objects for references (asset discovery)</li>
 *   <li>{@code generateCsr} → key pair + PKCS#10 CSR generated <em>on the sensor</em>; the private
 *       key is retained under the flow directory</li>
 *   <li>{@code installCertificate} → JSON import of certificate + key under a unique name, repoint
 *       every reference of the replaced certificate, delete the replaced certificate</li>
 *   <li>{@code validateCertificate} → confirm the new certificate is listed and its serial matches</li>
 * </ul>
 *
 * <p><b>Replace-in-place use case.</b> A FortiGate typically serves its factory certificate (or a
 * self-signed one) on the admin GUI and the SSL-VPN portal. Discovery surfaces every local
 * certificate as a selectable asset; when the operator selects one and TLM issues a certificate for
 * it, the asset's FortiOS name is round-tripped in {@code virtualServerName} and the install rotates
 * it out: the new certificate takes over every reference and the old one is deleted (built-in
 * certificates are only unbound, never deleted).
 */
@Slf4j
@WorkflowEntryPoint(name = "FortiGateAutomationPlugin")
@SuppressWarnings("unchecked")
public class FortiGateAutomationPlugin extends AbstractAutomationWorkflow {

    private static final String PLUGIN_NAME = FortiGateAutomationPluginHelper.PLUGIN_NAME;

    /** Port used for the synthetic per-certificate endpoint in discovery. */
    private static final Integer ENDPOINT_PORT = 443;

    private final MyPluginConfiguration extendedConfig;
    /** Null when the connector configuration is unusable; see {@link #configurationError}. */
    private final FortiGateAdapter adapter;
    private final String configurationError;
    private final String host;
    private final int port;
    private final boolean keepReplaced;

    public FortiGateAutomationPlugin(SdkContext context,
            PluginConfiguration<MyPluginConfiguration> configuration) {
        this.extendedConfig = Objects.requireNonNull(configuration.getExtendedConfig(),
                "Plugin extended configuration is required");
        final var secretsManager = extendedConfig.isSecretsManagerAuth();
        this.host = AdapterConfig.normalizeHost(extendedConfig.getHost());
        this.port = FortiGateAutomationPluginHelper.parseIntOrDefault(extendedConfig.getPort(), AdapterConfig.DEFAULT_PORT);
        this.keepReplaced = extendedConfig.isKeepReplacedCertificate();
        final var scope = extendedConfig.getCertificateScope() == null || extendedConfig.getCertificateScope().isBlank()
                ? AdapterConfig.SCOPE_GLOBAL : extendedConfig.getCertificateScope().trim().toLowerCase();
        log.info("Loaded extended configuration: host={} (raw '{}'), port={}, vdom={}, certificateScope={}, "
                + "authenticationMethod={}, pamConnectorId={}, replacedCertificate={}",
                host, extendedConfig.getHost(), port,
                Optional.ofNullable(extendedConfig.getVdom()).filter(v -> !v.isBlank()).orElse(AdapterConfig.DEFAULT_VDOM),
                scope, secretsManager ? "secrets-manager" : "direct-input",
                secretsManager ? extendedConfig.getPamConnectorId() : "n/a", keepReplaced ? "keep" : "delete");

        // Fail closed: never call the API without a token. In secrets-manager mode an empty value
        // means the PAM connector could not resolve the vault reference.
        final var token = decodeSecret(extendedConfig.getPassword());
        if (host == null) {
            this.configurationError = "FortiGate host is empty. Enter the appliance FQDN or IP on the connector.";
        } else if (token == null || token.isBlank()) {
            this.configurationError = secretsManager
                    ? "FortiGate REST API token was not resolved by the Secrets Manager (PAM) connector"
                            + (extendedConfig.getPamConnectorId() == null
                                    ? "" : " '" + extendedConfig.getPamConnectorId() + "'")
                            + ". Check the PAM connector's Test Connection and that the vault reference"
                            + " points at an existing secret the connector is allowed to read."
                    : "FortiGate REST API token is empty. Re-enter it on the connector, or if the connector"
                            + " uses Self-authentication (Secrets manager), check that the PAM connector"
                            + " resolved the vault reference.";
        } else if (!AdapterConfig.SCOPE_GLOBAL.equals(scope) && !AdapterConfig.SCOPE_VDOM.equals(scope)) {
            this.configurationError = "Certificate scope '" + scope + "' is not valid; use 'global' or 'vdom'.";
        } else if (port == 22) {
            // Seen in the field: the SSH port typed into the REST port field. The REST API needs the
            // HTTPS administrative-access port; talking TLS to sshd yields "plaintext connection?".
            this.configurationError = "FortiGate REST API port is 22, which is the SSH port. Enter the HTTPS "
                    + "administrative-access port (usually 443) in 'FortiGate HTTPS admin / REST API port'.";
        } else {
            this.configurationError = null;
        }
        if (configurationError != null) {
            log.error(configurationError);
            this.adapter = null;
            return;
        }
        log.info("FortiGate REST API token received ({} characters, redacted)", token.trim().length());

        this.adapter = new FortiGateAdapter(AdapterConfig.builder()
                .host(host)
                .port(port)
                .apiToken(token.trim())
                .vdom(extendedConfig.getVdom())
                .certificateScope(scope)
                .keepReplacedCertificate(keepReplaced)
                .build());
    }

    /**
     * TLM hands directly-entered plugin secrets over base64-encoded, while a secret injected by a
     * Secrets Manager (PAM) connector may arrive as plain text. Decode when the value is valid
     * base64 <em>and</em> the decoded bytes are printable text; otherwise use the value as-is.
     * FortiOS API tokens are alphanumeric and therefore also valid base64 — the printable-text test
     * keeps them intact: decoding random token characters yields control bytes, so the raw value is
     * used.
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
                    + "FortiGate certificate '{}' at install time",
                    csrRequest.getFlowId(), csrRequest.getSubjectDn(), csrRequest.getDnsNames(),
                    csrRequest.getKeyAlgorithm(), csrRequest.getKeySize(), csrRequest.getSignatureAlgorithm(),
                    replaced == null ? "<none - new certificate>" : replaced);

            final var csr = FortiGateAutomationPluginHelper.generateCsrAndStoreKey(
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
                certificates = FortiGateAutomationPluginHelper.splitChainPem(installRequest.getCertificateChain());
            } else if (installRequest.getCertificateLink() != null && !installRequest.getCertificateLink().isBlank()) {
                final Path pluginDir = FortiGateAutomationPluginHelper.flowDirectory(flowId);
                Files.createDirectories(pluginDir);
                final var downloaded = FortiGateAutomationPluginHelper.downloadFileToDirectory(
                        installRequest.getCertificateLink(), pluginDir.toString());
                certificates = FortiGateAutomationPluginHelper.extractCertificates(downloaded);
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
            final var leaf = FortiGateAutomationPluginHelper.parseFirstCertificate(leafPem);
            final var leafCn = CertificateAttributesUtil.getCommonName(leaf.getSubjectX500Principal().getName());
            final var leafSerial = CertificateAttributesUtil.serialHex(leaf);

            // The private key generated on this sensor during generateCsr.
            final var keyPem = FortiGateAutomationPluginHelper.readStoredPrivateKey(flowId);

            // Certificate file: leaf first; append the ICA when requested. FortiOS reads the first
            // block as the local certificate; a following intermediate is stored with it (the GUI
            // import accepts chain files), but intermediates are normally configured as CA certs.
            final var certFile = new StringBuilder(FortiGateAutomationPluginHelper.normalizePem(leafPem));
            final var ica = certificates.get("ica.cer");
            if (extended.isUseCommonIca() && ica != null && !ica.isBlank()) {
                certFile.append(FortiGateAutomationPluginHelper.normalizePem(ica));
            }

            // Which FortiGate certificate is being replaced? The alias TLM round-trips can be stale
            // (it keeps the first-discovered alias while every renewal creates a new FortiOS name),
            // so resolve through alias -> thumbprint -> endpoint -> subject, accepting only names
            // that exist on the appliance.
            final var newName = CertificateAttributesUtil.buildUniqueName(leafCn, leafSerial, "tlm_cert");
            final var currentCerts = adapter.listCertificates();
            final var selection = ReplacementResolver.resolve(
                    currentCerts,
                    adapter.knownCertificatePems(currentCerts),
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
                        + "certificates on FortiGate {} could be identified as it - the new certificate will be imported "
                        + "without repointing or deleting anything", extended.getVirtualServerName(),
                        installRequest.getCurrentCertificateThumbprint(),
                        currentCerts.stream().map(FortiGateCertificate::getName).toList());
            }

            final var installResult = adapter.installCertificate(newName, certFile.toString(), keyPem, leaf,
                    replacedNames, keepReplaced);

            final InstallCertificateResponse<JsonNode> response = new InstallCertificateResponse<>();
            if (installResult.isSuccess()) {
                final var installed = installResult.getValue();
                // Persist what validateCertificate needs (fresh JVM per call), then drop the key.
                final var record = new FlowRecord();
                record.setInstalledCertificateName(installed.getCertificateName());
                record.setInstalledCertificatePem(FortiGateAutomationPluginHelper.normalizePem(leafPem));
                record.setInstalledSerialNumber(leafSerial);
                record.setReplacedCertificateNames(replacedNames);
                record.setInstalledAt(OffsetDateTime.now().toString());
                FortiGateAutomationPluginHelper.writeFlowRecord(flowId, record);
                FortiGateAutomationPluginHelper.deleteStoredPrivateKey(flowId);
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
            final FlowRecord record = FortiGateAutomationPluginHelper.readFlowRecord(flowId);
            String name = record == null ? null : record.getInstalledCertificateName();
            String expectedSerial = record == null ? null : record.getInstalledSerialNumber();
            if (expectedSerial == null || expectedSerial.isBlank()) {
                expectedSerial = firstNonBlank(extended.getCertificateSerialNumber(), text(request, "certificateSerialNumber"));
            }
            if (name == null || name.isBlank()) {
                name = firstNonBlank(extended.getCertificateName(), stripPartition(extended.getVirtualServerName()));
            }
            if ((name == null || name.isBlank()) && expectedSerial != null) {
                // No record and no name: find the certificate by serial in the FortiGate list.
                final var serial = expectedSerial;
                name = adapter.listCertificates().stream()
                        .filter(c -> CertificateAttributesUtil.sameSerial(c.getSerialNumber(), serial))
                        .map(FortiGateCertificate::getName).findFirst().orElse(null);
            }
            final ValidateCertificateResponse<JsonNode> response = new ValidateCertificateResponse<>();
            if (name == null || name.isBlank()) {
                response.setErrors(List.of(new PluginError("CERTIFICATE_VALIDATION_ERROR",
                        "Cannot determine which FortiGate certificate to validate: no flow record for flow '" + flowId
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
                    log.warn("Certificate '{}' validated on the FortiGate but its PEM is not available to return", name);
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
                                         FortiGateConfigurationData data) {
        final var certificates = Optional.ofNullable(data.getCertificates()).orElseGet(List::of);

        // TLM's automation inventory is endpoint-centric and keys endpoints by dataIp:port. A
        // FortiGate certificate may be bound to the admin GUI, the SSL-VPN portal, several IPsec
        // tunnels or VIPs, or - like the factory certificate - to nothing the plugin scans. So each
        // certificate gets its own synthetic endpoint. Because every renewal imports the certificate
        // under a NEW FortiOS name (FortiOS cannot overwrite), the endpoint is derived from what
        // survives a renewal - the subject CN and the key algorithm: <cn>-<rsa|ecc>.<host>:443.
        // TLM therefore sees ONE endpoint across renewals, while the alias carries the current
        // FortiOS name so the install knows exactly which certificate to rotate out.
        final Map<String, String> endpoints = assignEndpoints(certificates, host);

        final var automationInfo = new RefreshConfigurationResponse.AutomationInfo();
        automationInfo.setManagementIp(host);
        automationInfo.setHostName(host);
        automationInfo.setOsName(FortiGateConfigurationData.OS_NAME);
        automationInfo.setOsFlavor("Fortinet FortiGate" + (data.getVersion() == null ? "" : " " + data.getVersion()));
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
                    // CN when known, else the FortiOS name, so the asset is always identifiable.
                    cert.setDomainName(c.getCommonName() != null ? c.getCommonName() : c.getName());
                    // PEM only when it could be fetched.
                    cert.setCertificate(c.getCertificatePem());
                    cert.setServerParam(c.getName());
                    cert.setSni(data.referencesOf(c.getName()).stream()
                            .anyMatch(r -> r.getType() == CertificateReference.Type.FIREWALL_VIP));
                    return cert;
                })
                .toList());
    }

    // ------------------------------------------------------------------ name resolution

    /**
     * The FortiGate certificate a CSR request intends to replace (informational at this stage): an
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
     * <p>The canonical host is {@code <sanitised CN>-<key type>.<fortigateHost>}, e.g.
     * {@code vpn-example-com-rsa.fgt.example.com}. It does not contain the FortiOS object name, so it
     * stays the same when a renewal imports the certificate under a new name — TLM keeps tracking a
     * single endpoint. When several certificates share CN and key type (e.g. the previous certificate
     * was kept after a rotation, or duplicates were uploaded by hand), the one expiring last owns the
     * canonical host and the others fall back to {@code <name>.<fortigateHost>} so nothing collapses
     * onto one endpoint. A certificate without a readable CN also uses the name-based host.
     */
    static Map<String, String> assignEndpoints(List<FortiGateCertificate> certificates, String host) {
        final Map<String, String> result = new java.util.LinkedHashMap<>();
        final Map<String, List<FortiGateCertificate>> byCanonical = new java.util.LinkedHashMap<>();
        for (FortiGateCertificate c : certificates) {
            final var canonical = canonicalEndpointHost(c, host);
            if (canonical == null) {
                result.put(c.getName(), nameEndpointHost(c.getName(), host));
            } else {
                byCanonical.computeIfAbsent(canonical, k -> new ArrayList<>()).add(c);
            }
        }
        for (var entry : byCanonical.entrySet()) {
            final var group = entry.getValue();
            // Newest (latest validTo) owns the stable endpoint.
            group.sort((a, b) -> Long.compare(Objects.requireNonNullElse(b.getValidToEpoch(), 0L),
                    Objects.requireNonNullElse(a.getValidToEpoch(), 0L)));
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

    /** {@code <sanitised CN>-<rsa|ecc|dsa|key>.<fortigateHost>}, or null when the CN is unknown. */
    private static String canonicalEndpointHost(FortiGateCertificate c, String host) {
        final var cn = c.getCommonName();
        if (cn == null || cn.isBlank()) {
            return null;
        }
        final var label = dnsLabel(cn) + "-" + (c.getKeyType() == null ? "key" : c.getKeyType());
        return label + "." + host;
    }

    /** {@code <sanitised name>.<fortigateHost>} — the fallback that is unique per FortiOS object. */
    private static String nameEndpointHost(String certName, String host) {
        if (certName == null || certName.isBlank()) {
            return host;
        }
        return dnsLabel(certName) + "." + host;
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

    private static String blankToNull(String value) {
        return value == null || value.isBlank() ? null : value.trim();
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
