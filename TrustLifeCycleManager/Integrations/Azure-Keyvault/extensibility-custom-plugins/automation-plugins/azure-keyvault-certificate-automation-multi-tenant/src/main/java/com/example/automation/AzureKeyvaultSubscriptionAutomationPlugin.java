package com.example.automation;

import java.nio.ByteBuffer;
import java.nio.charset.CharacterCodingException;
import java.nio.charset.CodingErrorAction;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.ArrayList;
import java.util.Arrays;
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
import com.example.automation.adapter.AzureKeyVaultSubscriptionAdapter;
import com.example.automation.extended.configuration.MyPluginConfiguration;
import com.example.automation.extended.request.MyGenerateCertificateRequest;
import com.example.automation.extended.request.MyInstallCertificateRequest;
import com.example.automation.extended.request.MyRefreshRequest;
import com.example.automation.extended.request.MyValidateRequest;
import com.example.automation.extended.response.MyRefreshResponse;
import com.example.automation.helper.AzureKeyvaultAutomationPluginHelper;
import com.example.automation.helper.CertificateAttributesUtil;
import com.example.automation.model.AzureKeyVaultConfigurationData;
import com.example.automation.model.AzureKeyVaultConfigurationData.CertificateAsset;
import com.example.automation.model.CertificateTarget;
import com.example.automation.model.ErrorCode;
import com.example.automation.model.KeyVaultInfo;
import com.example.automation.model.Result;
import com.fasterxml.jackson.databind.JsonNode;

import lombok.extern.slf4j.Slf4j;

/**
 * Azure Key Vault automation plugin for DigiCert Trust Lifecycle Manager, <b>subscription scope</b>:
 * one connector maps to one Azure subscription and manages every Key Vault in it. The SDK invokes
 * one of the five lifecycle methods; the plugin reads its configuration and delegates to a single
 * {@link AzureKeyVaultSubscriptionAdapter} that enumerates vaults through Azure Resource Manager and
 * drives each vault over the Azure Certificates SDK.
 *
 * <p><b>Identity across vaults.</b> TLM's automation inventory keys endpoints by {@code dataIp:port}
 * and round-trips a selected asset as {@code <partition>/<alias>}. This plugin sets the partition to
 * the <em>vault name</em> and the alias to the <em>certificate name</em>, and synthesises the endpoint
 * host as {@code <certName>.<vaultHost>}, so every certificate in every vault is a distinct asset and
 * a renewal always lands as a new version of the same object in the same vault.
 */
@Slf4j
@WorkflowEntryPoint(name = "AzureKeyvaultSubscriptionAutomationPlugin")
@SuppressWarnings("unchecked")
public class AzureKeyvaultSubscriptionAutomationPlugin extends AbstractAutomationWorkflow {

    private static final String PLUGIN_NAME = "AzureKeyvaultSubscriptionAutomationPlugin";

    /** The Key Vault data-plane port (HTTPS); used as the synthetic endpoint port in discovery. */
    private static final Integer VAULT_PORT = 443;

    private final MyPluginConfiguration extendedConfig;
    /** Null when the connector configuration is unusable; see {@link #configurationError}. */
    private final AzureKeyVaultSubscriptionAdapter adapter;
    private final String configurationError;
    private final String subscriptionId;
    private final boolean excludeExpired;
    private final boolean excludeDisabled;

    public AzureKeyvaultSubscriptionAutomationPlugin(SdkContext context,
            PluginConfiguration<MyPluginConfiguration> configuration) {
        this.extendedConfig = Objects.requireNonNull(configuration.getExtendedConfig(),
                "Plugin extended configuration is required");
        final var secretsManager = extendedConfig.isSecretsManagerAuth();
        log.info("Loaded extended configuration: subscriptionId={}, tenantId={}, clientId={}, "
                + "resourceGroups={}, vaultNamePattern={}, vaultTagFilter={}, "
                + "authenticationMethod={}, pamConnectorId={}",
                extendedConfig.getSubscriptionId(),
                extendedConfig.getTenantId(),
                extendedConfig.getClientId(),
                extendedConfig.getResourceGroups(),
                extendedConfig.getVaultNamePattern(),
                extendedConfig.getVaultTagFilter(),
                secretsManager ? "secrets-manager" : "direct-input",
                secretsManager ? extendedConfig.getPamConnectorId() : "n/a");

        this.subscriptionId = trimToNull(extendedConfig.getSubscriptionId());
        this.excludeExpired = Boolean.TRUE.equals(extendedConfig.getExcludeExpiredCertificates());
        this.excludeDisabled = Boolean.TRUE.equals(extendedConfig.getExcludeDisabledCertificates());

        // Fail closed: never build an Azure credential around a missing secret or subscription.
        final var clientSecret = decodeSecret(extendedConfig.getClientSecret());
        if (clientSecret == null || clientSecret.isBlank()) {
            this.configurationError = secretsManager
                    ? "Azure client secret was not resolved by the Secrets Manager (PAM) connector"
                            + (extendedConfig.getPamConnectorId() == null
                                    ? "" : " '" + extendedConfig.getPamConnectorId() + "'")
                            + ". Check the PAM connector's Test Connection and that the vault reference"
                            + " points at an existing secret the connector is allowed to read."
                    : "Azure client secret is empty. Re-enter it on the connector, or if the connector"
                            + " uses Self-authentication (Secrets manager), check that the PAM connector"
                            + " resolved the vault reference.";
            log.error(configurationError);
            this.adapter = null;
            return;
        }
        if (subscriptionId == null) {
            this.configurationError = "Azure Subscription ID is empty. Enter the subscription (GUID) "
                    + "whose Key Vaults this connector should manage.";
            log.error(configurationError);
            this.adapter = null;
            return;
        }
        log.info("Azure client secret received ({} characters, redacted)", clientSecret.length());

        this.configurationError = null;
        final var adapterConfig = AdapterConfig.builder()
                .tenantId(extendedConfig.getTenantId())
                .clientId(extendedConfig.getClientId())
                .clientSecret(clientSecret)
                .subscriptionId(subscriptionId)
                .resourceGroups(splitCsv(extendedConfig.getResourceGroups()))
                .vaultNamePattern(trimToNull(extendedConfig.getVaultNamePattern()))
                .vaultTagFilter(trimToNull(extendedConfig.getVaultTagFilter()))
                .build();
        this.adapter = new AzureKeyVaultSubscriptionAdapter(adapterConfig);
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

    // ------------------------------------------------------------------ lifecycle methods

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
                response.setErrors(List.of(
                        new PluginError(result.getErrorCode(), result.getErrorMessage())));
            }
            log.info("TestConnection response: {}", objectMapper.writeValueAsString(response));
            return response;
        } catch (Exception e) {
            throw new WorkflowExecutionException("Error in testConnection: " + e.getMessage(), e);
        }
    }

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

            final var dnsNames = CertificateAttributesUtil.getDnsNames(csrRequest.getDnsNames());
            final var azureSubject = CertificateAttributesUtil.toAzureSubject(csrRequest.getSubjectDn());
            final var emails = CertificateAttributesUtil.getEmailAddresses(csrRequest.getSubjectDn());
            final var keyType = mapKeyType(csrRequest.getKeyAlgorithm());

            final GenerateCsrResponse<JsonNode> response = new GenerateCsrResponse<>();
            final var target = resolveTarget(extended.getVaultName(), extended.getCertificateName(),
                    extended.getVirtualServerName());
            if (!target.isSuccess()) {
                response.setErrors(List.of(new PluginError(target.getErrorCode(), target.getErrorMessage())));
                log.info("GenerateCsr response: {}", objectMapper.writeValueAsString(response));
                return response;
            }
            final var t = target.getValue();
            final var generated = adapter.generateCsr(t.getVault(), t.getCertificateName(),
                    azureSubject, dnsNames, emails, csrRequest.getKeySize(), keyType);

            if (generated.isSuccess()) {
                response.setCsr(generated.getValue().getCsr());
                final var pluginDir = Path.of(System.getProperty("java.io.tmpdir"), PLUGIN_NAME,
                        csrRequest.getFlowId());
                Files.createDirectories(pluginDir);
                Files.writeString(pluginDir.resolve("request.csr"), generated.getValue().getCsr());
                // Remember which vault the CSR went to, so install/validate can fall back on it if
                // TLM does not round-trip the vault in a later request of the same flow.
                Files.writeString(pluginDir.resolve("target.txt"), t.toString());
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
        requireUsableConfiguration();
        try {
            log.info("InstallCertificate request: {}", objectMapper.writeValueAsString(request));

            final InstallCertificateRequest<MyInstallCertificateRequest> installRequest =
                    PluginUtils.convertWrappedObject(request, InstallCertificateRequest.class,
                            MyInstallCertificateRequest.class);
            final var extended = Optional.ofNullable(installRequest.getExtendedRequest())
                    .orElseGet(MyInstallCertificateRequest::new);

            final Map<String, String> certificates;
            if (installRequest.getCertificateChain() != null
                    && !installRequest.getCertificateChain().isBlank()) {
                certificates = AzureKeyvaultAutomationPluginHelper.splitChainPem(
                        installRequest.getCertificateChain());
            } else if (installRequest.getCertificateLink() != null
                    && !installRequest.getCertificateLink().isBlank()) {
                final var pluginDir = Path.of(System.getProperty("java.io.tmpdir"), PLUGIN_NAME,
                        installRequest.getFlowId());
                Files.createDirectories(pluginDir);
                final var downloaded = AzureKeyvaultAutomationPluginHelper.downloadFileToDirectory(
                        installRequest.getCertificateLink(), pluginDir.toString());
                certificates = AzureKeyvaultAutomationPluginHelper.extractCertificatesFromZip(downloaded);
            } else {
                throw new WorkflowExecutionException(
                        "InstallCertificate request must include certificateChain or certificateLink",
                        new IllegalArgumentException("missing cert source"));
            }
            if (!certificates.containsKey("end_entity.cer")) {
                throw new WorkflowExecutionException(
                        "End-entity certificate not found in supplied artifact", null);
            }

            final InstallCertificateResponse<JsonNode> response = new InstallCertificateResponse<>();
            final var target = resolveTargetForFlow(extended.getVaultName(), extended.getCertificateName(),
                    extended.getVirtualServerName(), installRequest.getFlowId());
            if (!target.isSuccess()) {
                response.setErrors(List.of(new PluginError(target.getErrorCode(), target.getErrorMessage())));
                log.info("InstallCertificate response: {}", objectMapper.writeValueAsString(response));
                return response;
            }
            final var t = target.getValue();

            final var pemChain = new ArrayList<String>();
            pemChain.add(certificates.get("end_entity.cer"));
            final var ica = certificates.get("ica.cer");
            if (extended.isUseCommonIca() && ica != null && !ica.isBlank()) {
                pemChain.add(ica);
            }

            final var installResult = adapter.installCertificate(t.getVault(), t.getCertificateName(),
                    pemChain, installRequest.getCurrentCertificateThumbprint());
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
        requireUsableConfiguration();
        try {
            log.info("ValidateCertificate request: {}", objectMapper.writeValueAsString(request));

            final ValidateCertificateRequest<MyValidateRequest> validateRequest =
                    PluginUtils.convertWrappedObject(request, ValidateCertificateRequest.class,
                            MyValidateRequest.class);
            final var extended = Optional.ofNullable(validateRequest.getExtendedRequest())
                    .orElseGet(MyValidateRequest::new);

            final ValidateCertificateResponse<JsonNode> response = new ValidateCertificateResponse<>();
            final var target = resolveTargetForFlow(extended.getVaultName(), extended.getCertificateName(),
                    extended.getVirtualServerName(), validateRequest.getFlowId());
            if (!target.isSuccess()) {
                response.setErrors(List.of(new PluginError(target.getErrorCode(), target.getErrorMessage())));
                log.info("ValidateCertificate response: {}", objectMapper.writeValueAsString(response));
                return response;
            }
            final var t = target.getValue();
            final var validateResult = adapter.validateCertificate(t.getVault(), t.getCertificateName());
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
        requireUsableConfiguration();
        try {
            final RefreshConfigurationRequest<MyRefreshRequest> refreshRequest =
                    PluginUtils.convertWrappedObject(request, RefreshConfigurationRequest.class,
                            MyRefreshRequest.class);
            log.info("RefreshConfiguration request: {}", objectMapper.writeValueAsString(refreshRequest));

            final var configResult = adapter.getConfigurationData(excludeExpired, excludeDisabled);
            if (!configResult.isSuccess()) {
                final RefreshConfigurationResponse<JsonNode> errorResponse =
                        new RefreshConfigurationResponse<>();
                errorResponse.setErrors(List.of(
                        new PluginError(configResult.getErrorCode(), configResult.getErrorMessage())));
                log.info("RefreshConfiguration response (error): {}",
                        objectMapper.writeValueAsString(errorResponse));
                return errorResponse;
            }

            final RefreshConfigurationResponse<MyRefreshResponse> typedResponse =
                    new RefreshConfigurationResponse<>();
            populateRefreshResponse(typedResponse, configResult.getValue());

            final RefreshConfigurationResponse<JsonNode> refreshResponse =
                    PluginUtils.convertWrappedObject(typedResponse, RefreshConfigurationResponse.class,
                            JsonNode.class);
            log.info("RefreshConfiguration response: {}", objectMapper.writeValueAsString(refreshResponse));
            return refreshResponse;
        } catch (Exception e) {
            throw new WorkflowExecutionException("Error in refreshConfiguration: " + e.getMessage(), e);
        }
    }

    // ------------------------------------------------------------------ discovery mapping

    private void populateRefreshResponse(RefreshConfigurationResponse<MyRefreshResponse> response,
                                         AzureKeyVaultConfigurationData data) {
        final var sub = Optional.ofNullable(data.getSubscriptionInfo())
                .orElseGet(AzureKeyVaultConfigurationData.SubscriptionInfo::new);
        final var certificates = Optional.ofNullable(data.getCertificates()).orElseGet(List::of);
        final var vaults = Optional.ofNullable(data.getVaults()).orElseGet(List::of);

        // TLM's automation inventory is endpoint-centric and keys endpoints by dataIp:port, so each
        // certificate gets its own synthetic endpoint <certName>.<vaultHost>:443 — unique across
        // vaults because the vault FQDN is part of it. The vault name travels as the endpoint
        // PARTITION and the certificate name as the ALIAS; TLM round-trips the pair as
        // "<partition>/<alias>" in virtualServerName, which is how a renewal finds its vault.
        final var automationInfo = new RefreshConfigurationResponse.AutomationInfo();
        automationInfo.setManagementIp(subscriptionId);
        automationInfo.setHostName(sub.getDisplayName() != null ? sub.getDisplayName() : subscriptionId);
        automationInfo.setOsName(AzureKeyVaultConfigurationData.AZURE_KEY_VAULT);
        automationInfo.setOsFlavor("Azure Key Vault (subscription)");
        automationInfo.setOsVersion(vaults.size() + " vault(s)");
        automationInfo.setPartitions(vaults.stream().map(KeyVaultInfo::getName).toArray(String[]::new));
        automationInfo.setDataIps(certificates.stream()
                .map(this::endpointHost)
                .toArray(String[]::new));
        response.setAutomationInfo(automationInfo);

        response.setDataIpInfo(certificates.stream()
                .map(c -> {
                    final var info = new RefreshConfigurationResponse.DataIpInfo();
                    info.setManagementIp(subscriptionId);
                    info.setDataIp(endpointHost(c));
                    info.setPort(VAULT_PORT);
                    info.setPartition(c.getVaultName());
                    info.setAlias(c.getName());
                    info.setSslState(c.isEnabled() ? 1 : 0);
                    return info;
                })
                .toList());

        response.setCertificates(certificates.stream()
                .map(c -> {
                    final var cert = new RefreshConfigurationResponse.Certificate();
                    final var host = endpointHost(c);
                    cert.setIpAddress(host);
                    cert.setPort(VAULT_PORT);
                    cert.setIpAndPort(host == null ? null : host + ":" + VAULT_PORT);
                    cert.setDomainName(c.getSubject() != null ? c.getSubject() : c.getName());
                    cert.setCertificate(c.getCertificate());
                    cert.setServerParam(c.getName());
                    cert.setSni(false);
                    return cert;
                })
                .toList());
    }

    /** {@code <certName>.<vaultHost>}, e.g. {@code test-03.myvault.vault.azure.net}. */
    private String endpointHost(CertificateAsset c) {
        final var host = hostOf(c.getVaultUri());
        if (c.getName() == null || c.getName().isBlank()) {
            return host;
        }
        return host == null ? c.getName() : c.getName() + "." + host;
    }

    private static String hostOf(String url) {
        if (url == null || url.isBlank()) {
            return null;
        }
        var host = url.replaceFirst("^https?://", "");
        final int slash = host.indexOf('/');
        if (slash >= 0) {
            host = host.substring(0, slash);
        }
        return host.isBlank() ? null : host;
    }

    // ------------------------------------------------------------------ target resolution

    /**
     * Resolves the (vault, certificate name) an existing certificate request acts on. This plugin
     * only renews / replaces certificates that already exist in a vault (switching them to a
     * DigiCert-issued certificate as a new version); it never invents a name for a brand-new object.
     * <ol>
     *   <li><b>Certificate name</b>: an explicit {@code certificateName} (optionally written as
     *       {@code <vault>/<name>}), else the alias round-tripped in {@code virtualServerName}. Both
     *       are used verbatim so the new version lands on the existing object. Neither present →
     *       {@code CERTIFICATE_NOT_TARGETED}.</li>
     *   <li><b>Vault</b>: an explicit {@code vaultName}, else the {@code <vault>/} prefix of
     *       {@code certificateName}, else the partition round-tripped in {@code virtualServerName},
     *       else the single readable vault in the subscription that holds a certificate of that
     *       name (an ambiguous name is an error, never a guess).</li>
     * </ol>
     */
    private Result<CertificateTarget> resolveTarget(String explicitVault, String explicitName,
                                                    String virtualServerName) {
        String vaultName = trimToNull(explicitVault);
        String certName = null;

        final var explicit = splitVaultAndName(explicitName);
        if (explicit[1] != null) {
            certName = explicit[1];
            if (vaultName == null) {
                vaultName = explicit[0];
            }
        }
        final var asset = splitVaultAndName(virtualServerName);
        if (certName == null) {
            certName = asset[1];
        }
        if (vaultName == null) {
            vaultName = asset[0];
        }
        if (certName == null) {
            return Result.failure("The request does not identify an existing Key Vault certificate "
                    + "(no certificateName and no discovered asset in virtualServerName). This "
                    + "connector renews certificates that already exist in a vault; select a "
                    + "discovered certificate in TLM or pass certificateName as <vault>/<name>.",
                    ErrorCode.CERTIFICATE_NOT_TARGETED.name());
        }

        final Result<KeyVaultInfo> vault;
        if (vaultName != null) {
            vault = adapter.resolveVault(vaultName);
        } else {
            log.warn("Request carries certificate {} without its vault; searching the subscription", certName);
            vault = adapter.findVaultHoldingCertificate(certName);
        }
        if (!vault.isSuccess()) {
            return Result.failure(vault.getErrorMessage(), vault.getErrorCode());
        }
        final var target = new CertificateTarget(vault.getValue(), certName);
        log.info("Resolved target {}", target);
        return Result.success(target);
    }

    /**
     * Like {@link #resolveTarget} but, when the request carries no vault at all, first consults the
     * target recorded by {@code generateCsr} for the same flow — the pending version can only be
     * completed in the vault the CSR came from.
     */
    private Result<CertificateTarget> resolveTargetForFlow(String explicitVault, String explicitName,
                                                           String virtualServerName, String flowId) {
        final boolean hasVault = trimToNull(explicitVault) != null
                || splitVaultAndName(explicitName)[0] != null
                || splitVaultAndName(virtualServerName)[0] != null;
        if (!hasVault && flowId != null && !flowId.isBlank()) {
            try {
                final var recorded = Path.of(System.getProperty("java.io.tmpdir"), PLUGIN_NAME, flowId,
                        "target.txt");
                if (Files.exists(recorded)) {
                    final var parts = splitVaultAndName(Files.readString(recorded).trim());
                    if (parts[0] != null && parts[1] != null) {
                        log.info("Using the target recorded at CSR generation for flow {}: {}/{}",
                                flowId, parts[0], parts[1]);
                        return resolveTarget(parts[0], parts[1], null);
                    }
                }
            } catch (Exception e) {
                log.warn("Could not read the recorded target for flow {}: {}", flowId, e.getMessage());
            }
        }
        return resolveTarget(explicitVault, explicitName, virtualServerName);
    }

    /**
     * Splits {@code <vault>/<name>} into {@code [vault, name]}. Either part may come back null: a
     * bare name has no vault, and TLM renders a missing partition as the literal {@code null}.
     */
    static String[] splitVaultAndName(String value) {
        if (value == null || value.isBlank()) {
            return new String[] {null, null};
        }
        final var v = value.trim();
        final int slash = v.lastIndexOf('/');
        if (slash < 0) {
            return new String[] {null, v};
        }
        var vault = trimToNull(v.substring(0, slash));
        if (vault != null && (vault.equalsIgnoreCase("null") || vault.equalsIgnoreCase("none"))) {
            vault = null;
        }
        return new String[] {vault, trimToNull(v.substring(slash + 1))};
    }

    private static List<String> splitCsv(String csv) {
        if (csv == null || csv.isBlank()) {
            return List.of();
        }
        return Arrays.stream(csv.split("[,;]"))
                .map(String::trim)
                .filter(s -> !s.isEmpty())
                .toList();
    }

    private static String trimToNull(String s) {
        if (s == null) {
            return null;
        }
        final var t = s.trim();
        return t.isEmpty() ? null : t;
    }

    private static String mapKeyType(String keyAlgorithm) {
        if (keyAlgorithm == null) {
            return "rsa";
        }
        final var lower = keyAlgorithm.toLowerCase();
        return (lower.startsWith("ec") || lower.startsWith("ecdsa")) ? "ec" : "rsa";
    }
}
