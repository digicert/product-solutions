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
import com.example.automation.adapter.AzureKeyVaultAdapter;
import com.example.automation.extended.configuration.MyPluginConfiguration;
import com.example.automation.extended.request.MyGenerateCertificateRequest;
import com.example.automation.extended.request.MyInstallCertificateRequest;
import com.example.automation.extended.request.MyRefreshRequest;
import com.example.automation.extended.request.MyValidateRequest;
import com.example.automation.extended.response.MyRefreshResponse;
import com.example.automation.helper.AzureKeyvaultAutomationPluginHelper;
import com.example.automation.helper.CertificateAttributesUtil;
import com.example.automation.model.AzureKeyVaultConfigurationData;
import com.fasterxml.jackson.databind.JsonNode;

import lombok.extern.slf4j.Slf4j;

/**
 * Azure Key Vault automation plugin for DigiCert Trust Lifecycle Manager. The SDK invokes one of the
 * five lifecycle methods; the plugin reads its configuration and delegates to a single
 * {@link AzureKeyVaultAdapter} that drives one vault over the Azure Certificates SDK:
 * <ul>
 *   <li>{@code generateCsr} → {@code beginCreateCertificate} with the {@code Unknown} issuer (Azure
 *       generates the key and returns a CSR)</li>
 *   <li>{@code installCertificate} → {@code mergeCertificate} of the CA-signed chain (completes the
 *       pending version)</li>
 *   <li>{@code validateCertificate} → {@code getCertificate}</li>
 *   <li>{@code refreshConfiguration} → {@code listPropertiesOfCertificates} (asset discovery)</li>
 * </ul>
 *
 * <p><b>New-version use case.</b> Azure Key Vault treats a create against an existing certificate
 * <em>name</em> as a new version. So when a customer selects a discovered certificate that has no
 * managed TLM certificate yet, the plugin targets that certificate by name and the renewed
 * certificate lands as a new version of the same object. The name is taken from the explicit
 * {@code certificateName} field when supplied, otherwise derived from the CN/flow.
 */
@Slf4j
@WorkflowEntryPoint(name = "AzureKeyvaultAutomationPlugin")
@SuppressWarnings("unchecked")
public class AzureKeyvaultAutomationPlugin extends AbstractAutomationWorkflow {

    private static final String PLUGIN_NAME = "AzureKeyvaultAutomationPlugin";

    /** Azure Key Vault certificate names: {@code ^[0-9a-zA-Z-]+$}, max 127 characters. */
    private static final int MAX_NAME_LENGTH = 127;

    /** The Key Vault data-plane port (HTTPS); used as the synthetic endpoint port in discovery. */
    private static final Integer VAULT_PORT = 443;

    private final MyPluginConfiguration extendedConfig;
    private final AzureKeyVaultAdapter adapter;
    private final String keyVaultUrl;
    private final boolean excludeExpired;
    private final boolean excludeDisabled;

    public AzureKeyvaultAutomationPlugin(SdkContext context,
            PluginConfiguration<MyPluginConfiguration> configuration) {
        this.extendedConfig = Objects.requireNonNull(configuration.getExtendedConfig(),
                "Plugin extended configuration is required");
        log.info("Loaded extended configuration: keyVaultUrl={}, tenantId={}, clientId={}",
                extendedConfig.getKeyVaultUrl(),
                extendedConfig.getTenantId(),
                extendedConfig.getClientId());

        this.keyVaultUrl = extendedConfig.getKeyVaultUrl();
        this.excludeExpired = Boolean.TRUE.equals(extendedConfig.getExcludeExpiredCertificates());
        this.excludeDisabled = Boolean.TRUE.equals(extendedConfig.getExcludeDisabledCertificates());
        final var adapterConfig = AdapterConfig.builder()
                .tenantId(extendedConfig.getTenantId())
                .clientId(extendedConfig.getClientId())
                .clientSecret(decodeSecret(extendedConfig.getClientSecret()))
                .vaultUrl(extendedConfig.getKeyVaultUrl())
                .build();
        this.adapter = new AzureKeyVaultAdapter(adapterConfig);
    }

    /**
     * TLM hands plugin secrets over base64-encoded. If the value doesn't decode cleanly (someone
     * passed plain text), fall back to the original string rather than failing hard.
     */
    private static String decodeSecret(String raw) {
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
        try {
            log.info("GenerateCsr request: {}", objectMapper.writeValueAsString(request));

            final GenerateCsrRequest<MyGenerateCertificateRequest> csrRequest =
                    PluginUtils.convertWrappedObject(request, GenerateCsrRequest.class,
                            MyGenerateCertificateRequest.class);

            final var extended = Optional.ofNullable(csrRequest.getExtendedRequest())
                    .orElseGet(MyGenerateCertificateRequest::new);

            final var commonName = CertificateAttributesUtil.getCommonName(csrRequest.getSubjectDn());
            final var dnsNames = CertificateAttributesUtil.getDnsNames(csrRequest.getDnsNames());
            // Azure rejects a subject DN that carries emailAddress; move it to the SAN and pass a
            // cleaned, RFC 4514-valid subject.
            final var azureSubject = CertificateAttributesUtil.toAzureSubject(csrRequest.getSubjectDn());
            final var emails = CertificateAttributesUtil.getEmailAddresses(csrRequest.getSubjectDn());
            final var certName = resolveCertName(extended.getCertificateName(),
                    extended.getVirtualServerName(), commonName,
                    csrRequest.getFlowId(), extended.getFlowStartDate());
            final var keyType = mapKeyType(csrRequest.getKeyAlgorithm());

            final var generated = adapter.generateCsr(
                    certName, azureSubject, dnsNames, emails, csrRequest.getKeySize(), keyType);

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

            final var commonName = CertificateAttributesUtil.getCommonName(extended.getSubjectDn());
            final var certName = resolveCertName(extended.getCertificateName(),
                    extended.getVirtualServerName(), commonName,
                    installRequest.getFlowId(), extended.getFlowStartDate());

            // Merge the signed leaf; include the intermediate to complete the chain when requested.
            final var pemChain = new ArrayList<String>();
            pemChain.add(certificates.get("end_entity.cer"));
            final var ica = certificates.get("ica.cer");
            if (extended.isUseCommonIca() && ica != null && !ica.isBlank()) {
                pemChain.add(ica);
            }

            final var installResult = adapter.installCertificate(
                    certName, pemChain, installRequest.getCurrentCertificateThumbprint());

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
            final var certName = resolveCertName(extended.getCertificateName(),
                    extended.getVirtualServerName(), commonName,
                    validateRequest.getFlowId(), extended.getFlowStartDate());

            final var validateResult = adapter.validateCertificate(certName);

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

            final var configResult = adapter.getConfigurationData(excludeExpired, excludeDisabled);

            if (!configResult.isSuccess()) {
                // Return the error response directly: PluginError has no default constructor, so
                // round-tripping it through PluginUtils.convertWrappedObject (as the success path
                // does for the typed AutomationInfo) would fail to deserialize.
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

    private void populateRefreshResponse(RefreshConfigurationResponse<MyRefreshResponse> response,
                                         AzureKeyVaultConfigurationData data) {
        final var vaultInfo = Optional.ofNullable(data.getVaultInfo())
                .orElseGet(AzureKeyVaultConfigurationData.VaultInfo::new);
        final var certificates = Optional.ofNullable(data.getCertificates()).orElseGet(List::of);

        // TLM's automation inventory is endpoint-centric: a certificate only renders when it is
        // anchored to a data IP:port (the F5/NetScaler "cert in use on a virtual server" model),
        // and TLM keys endpoints by dataIp:port. A Key Vault has no per-certificate data-plane
        // IP:port, so we synthesize a UNIQUE endpoint per certificate using its Key Vault name as
        // the host. Using a single shared host would collapse every certificate onto one endpoint,
        // so TLM would keep only the first cert's alias and every renewal would target that first
        // certificate. The cert name is the natural unique identity and is also what round-trips as
        // the alias (see resolveCertName), so each certificate is tracked and renewed independently.
        final var vaultHost = vaultHost();

        final var automationInfo = new RefreshConfigurationResponse.AutomationInfo();
        automationInfo.setManagementIp(keyVaultUrl);
        automationInfo.setHostName(vaultInfo.getVaultName());
        automationInfo.setOsName(AzureKeyVaultConfigurationData.VaultInfo.AZURE_KEY_VAULT);
        automationInfo.setOsFlavor("Azure Key Vault");
        automationInfo.setDataIps(certificates.stream()
                .map(c -> endpointHost(c.getName()))
                .toArray(String[]::new));
        response.setAutomationInfo(automationInfo);

        // Each certificate object is a discoverable asset on its own unique endpoint. Its Azure name
        // is round-tripped as the alias so that selecting a discovered certificate feeds its name
        // back into a renewal request (creating a new version). sslState mirrors the enabled flag.
        response.setDataIpInfo(certificates.stream()
                .map(c -> {
                    final var info = new RefreshConfigurationResponse.DataIpInfo();
                    info.setManagementIp(keyVaultUrl);
                    info.setDataIp(endpointHost(c.getName()));
                    info.setPort(VAULT_PORT);
                    info.setAlias(c.getName());
                    info.setSslState(c.isEnabled() ? 1 : 0);
                    return info;
                })
                .toList());

        response.setCertificates(certificates.stream()
                .map(c -> {
                    final var cert = new RefreshConfigurationResponse.Certificate();
                    // Anchor the cert to its own unique endpoint so TLM inventories and renews it
                    // independently (see note above).
                    final var host = endpointHost(c.getName());
                    cert.setIpAddress(host);
                    cert.setPort(VAULT_PORT);
                    cert.setIpAndPort(host == null ? null : host + ":" + VAULT_PORT);
                    // Fall back to the Key Vault name when the subject is unknown (e.g. a disabled
                    // cert whose material could not be read) so the asset is still identifiable.
                    cert.setDomainName(c.getSubject() != null ? c.getSubject() : c.getName());
                    // PEM only — never the name; TLM parses this to show expiry/issuer/self-signed.
                    // Null is fine (disabled cert): the asset still shows via domainName/serverParam.
                    cert.setCertificate(c.getCertificate());
                    cert.setServerParam(c.getName());
                    cert.setSni(false);
                    return cert;
                })
                .toList());
    }

    /**
     * Resolves the Azure Key Vault certificate name to target, in priority order:
     * <ol>
     *   <li>an explicit {@code certificateName} from the extended request (user override), or</li>
     *   <li>the discovered asset's name round-tripped in {@code virtualServerName} — reusing an
     *       existing certificate name so Azure creates a <em>new version</em> of it, or</li>
     *   <li>a derived {@code CN-date-flow} value for a brand-new certificate.</li>
     * </ol>
     * The first two are the "renew this discovered certificate" path; the third is "create new".
     */
    private String resolveCertName(String explicit, String virtualServerName, String commonName,
                                   String flowId, String flowStartDate) {
        if (explicit != null && !explicit.isBlank()) {
            return CertificateAttributesUtil.sanitizeName(explicit, MAX_NAME_LENGTH);
        }
        final var fromAsset = stripPartition(virtualServerName);
        if (fromAsset != null && !fromAsset.isBlank()) {
            // Existing Key Vault certificate name — use verbatim so the new version lands on it.
            return fromAsset;
        }
        return CertificateAttributesUtil.getObjectName(commonName, flowId, flowStartDate, MAX_NAME_LENGTH);
    }

    /**
     * TLM round-trips the discovered asset as {@code <partition>/<name>} (e.g.
     * {@code null/selfsigned-certificate}); Key Vault names never contain a slash, so the segment
     * after the last {@code /} is the certificate name.
     */
    private static String stripPartition(String virtualServerName) {
        if (virtualServerName == null || virtualServerName.isBlank()) {
            return null;
        }
        final int slash = virtualServerName.lastIndexOf('/');
        final var name = slash >= 0 ? virtualServerName.substring(slash + 1) : virtualServerName;
        return name.isBlank() ? null : name;
    }

    /**
     * A unique, stable endpoint host for one certificate: {@code <certName>.<vaultHost>}
     * (e.g. {@code test-03.myvault.vault.azure.net}). Uniqueness per certificate is what keeps TLM
     * from collapsing every certificate onto one shared endpoint; scoping it under the vault host
     * keeps the displayed location meaningful. Falls back to the bare certificate name if the vault
     * host can't be derived.
     */
    private String endpointHost(String certName) {
        final var host = vaultHost();
        if (certName == null || certName.isBlank()) {
            return host;
        }
        return host == null ? certName : certName + "." + host;
    }

    /** The vault FQDN (host) from the configured URL, e.g. {@code myvault.vault.azure.net}, or null. */
    private String vaultHost() {
        if (keyVaultUrl == null || keyVaultUrl.isBlank()) {
            return null;
        }
        var host = keyVaultUrl.replaceFirst("^https?://", "");
        final int slash = host.indexOf('/');
        if (slash >= 0) {
            host = host.substring(0, slash);
        }
        return host.isBlank() ? null : host;
    }

    private static String mapKeyType(String keyAlgorithm) {
        if (keyAlgorithm == null) {
            return "rsa";
        }
        final var lower = keyAlgorithm.toLowerCase();
        return (lower.startsWith("ec") || lower.startsWith("ecdsa")) ? "ec" : "rsa";
    }
}
