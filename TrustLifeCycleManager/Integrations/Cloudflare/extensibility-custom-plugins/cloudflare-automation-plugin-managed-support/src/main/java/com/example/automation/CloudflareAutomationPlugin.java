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
import com.example.automation.adapter.CloudflareAdapter;
import com.example.automation.extended.configuration.MyPluginConfiguration;
import com.example.automation.extended.request.MyGenerateCertificateRequest;
import com.example.automation.extended.request.MyInstallCertificateRequest;
import com.example.automation.extended.request.MyRefreshRequest;
import com.example.automation.extended.request.MyValidateRequest;
import com.example.automation.extended.response.MyRefreshResponse;
import com.example.automation.helper.CertificateAttributesUtil;
import com.example.automation.helper.CloudflareAutomationPluginHelper;
import com.example.automation.helper.ReplacementResolver;
import com.example.automation.model.CloudflareCertificate;
import com.example.automation.model.CloudflareConfigurationData;
import com.example.automation.model.FlowRecord;
import com.fasterxml.jackson.databind.JsonNode;

import lombok.extern.slf4j.Slf4j;

/**
 * Cloudflare certificate automation plugin for DigiCert Trust Lifecycle Manager, with support for
 * replacing Cloudflare-managed certificates (Universal SSL / Advanced Certificate Manager, issued by
 * Google Trust Services, Let's Encrypt or SSL.com) with custom (DigiCert) certificates. The SDK
 * invokes one of the five lifecycle methods; the plugin reads its configuration and delegates to a
 * single {@link CloudflareAdapter} that drives one Cloudflare zone over the v4 API:
 * <ul>
 *   <li>{@code refreshConfiguration} → list the zone's custom certificates and (unless ignored) its
 *       Cloudflare-managed certificate packs, and fetch their bodies from the Cloudflare edge
 *       (asset discovery)</li>
 *   <li>{@code generateCsr} → key pair + CSR generated <em>by Cloudflare</em> (default; the private
 *       key never leaves Cloudflare) or on the sensor</li>
 *   <li>{@code installCertificate} → update the existing custom certificate in place (default), or
 *       upload a new one and delete/keep the replaced one; when the replaced asset is a
 *       Cloudflare-managed certificate, upload a new custom certificate and keep or retire the
 *       managed one (disable Universal SSL / delete the Advanced pack) per connector setting</li>
 *   <li>{@code validateCertificate} → confirm the custom certificate is active with the issued
 *       certificate's expiry; probe the edge for the served serial</li>
 * </ul>
 */
@Slf4j
@WorkflowEntryPoint(name = "CloudflareAutomationPlugin")
@SuppressWarnings("unchecked")
public class CloudflareAutomationPlugin extends AbstractAutomationWorkflow {

    /** Port used for the per-certificate endpoint in discovery (the Cloudflare edge always serves 443). */
    private static final Integer ENDPOINT_PORT = 443;

    private final MyPluginConfiguration extendedConfig;
    /** Null when the connector configuration is unusable; see {@link #configurationError}. */
    private final CloudflareAdapter adapter;
    private final AdapterConfig adapterConfig;
    private final String configurationError;
    private final String zoneId;

    public CloudflareAutomationPlugin(SdkContext context,
            PluginConfiguration<MyPluginConfiguration> configuration) {
        this.extendedConfig = Objects.requireNonNull(configuration.getExtendedConfig(),
                "Plugin extended configuration is required");
        final var secretsManager = extendedConfig.isSecretsManagerAuth();
        this.zoneId = AdapterConfig.normalizeZoneId(extendedConfig.getZoneId());
        final var csrMode = blankToDefault(extendedConfig.getCsrMode(), AdapterConfig.CSR_MODE_CLOUDFLARE).toLowerCase();
        final var strategy = blankToDefault(extendedConfig.getRenewalStrategy(), AdapterConfig.STRATEGY_UPDATE).toLowerCase();
        final var type = blankToDefault(extendedConfig.getCertificateType(), AdapterConfig.TYPE_SNI_CUSTOM).toLowerCase();
        final var bundle = blankToDefault(extendedConfig.getBundleMethod(), AdapterConfig.BUNDLE_FORCE).toLowerCase();
        final int retention = CloudflareAutomationPluginHelper.parseIntOrDefault(extendedConfig.getCsrRetention(),
                AdapterConfig.DEFAULT_CSR_RETENTION);
        final var managedMode = blankToDefault(extendedConfig.getManagedCertificates(), AdapterConfig.MANAGED_DISCOVER_KEEP).toLowerCase();
        log.info("Loaded extended configuration: zoneId={} (raw '{}'), csrMode={}, renewalStrategy={}, certificateType={}, "
                + "bundleMethod={}, csrRetention={}, managedCertificates={}, csrSubjectFallback=[{}], authenticationMethod={}, pamConnectorId={}",
                zoneId, extendedConfig.getZoneId(), csrMode, strategy, type, bundle, retention, managedMode,
                extendedConfig.getCsrSubjectFallback(), secretsManager ? "secrets-manager" : "direct-input",
                secretsManager ? extendedConfig.getPamConnectorId() : "n/a");

        // Fail closed: never call the API without a token. In secrets-manager mode an empty value
        // means the PAM connector could not resolve the vault reference.
        final var token = decodeSecret(extendedConfig.getPassword());
        if (zoneId == null) {
            this.configurationError = "Cloudflare Zone ID is empty. Enter the 32-character zone id on the connector.";
        } else if (!AdapterConfig.looksLikeZoneId(zoneId)) {
            this.configurationError = "'" + zoneId + "' does not look like a Cloudflare Zone ID (32 hexadecimal characters; "
                    + "zone Overview > API section in the Cloudflare dashboard).";
        } else if (token == null || token.isBlank()) {
            this.configurationError = secretsManager
                    ? "Cloudflare API token was not resolved by the Secrets Manager (PAM) connector"
                            + (extendedConfig.getPamConnectorId() == null
                                    ? "" : " '" + extendedConfig.getPamConnectorId() + "'")
                            + ". Check the PAM connector's Test Connection and that the vault reference"
                            + " points at an existing secret the connector is allowed to read."
                    : "Cloudflare API token is empty. Re-enter it on the connector, or if the connector"
                            + " uses Self-authentication (Secrets manager), check that the PAM connector"
                            + " resolved the vault reference.";
        } else if (!List.of(AdapterConfig.CSR_MODE_CLOUDFLARE, AdapterConfig.CSR_MODE_SENSOR).contains(csrMode)) {
            this.configurationError = "CSR mode '" + csrMode + "' is not valid; use 'cloudflare' or 'sensor'.";
        } else if (!List.of(AdapterConfig.STRATEGY_UPDATE, AdapterConfig.STRATEGY_REPLACE_DELETE,
                AdapterConfig.STRATEGY_REPLACE_KEEP).contains(strategy)) {
            this.configurationError = "Renewal strategy '" + strategy + "' is not valid; use 'update', 'replace_delete' or 'replace_keep'.";
        } else if (!List.of(AdapterConfig.TYPE_SNI_CUSTOM, AdapterConfig.TYPE_LEGACY_CUSTOM).contains(type)) {
            this.configurationError = "Certificate type '" + type + "' is not valid; use 'sni_custom' or 'legacy_custom'.";
        } else if (!List.of(AdapterConfig.BUNDLE_FORCE, AdapterConfig.BUNDLE_UBIQUITOUS, AdapterConfig.BUNDLE_OPTIMAL).contains(bundle)) {
            this.configurationError = "Bundle method '" + bundle + "' is not valid; use 'force', 'ubiquitous' or 'optimal'.";
        } else if (!List.of(AdapterConfig.MANAGED_DISCOVER_KEEP, AdapterConfig.MANAGED_DISCOVER_RETIRE, AdapterConfig.MANAGED_IGNORE)
                .contains(managedMode)) {
            this.configurationError = "Cloudflare-managed certificates setting '" + managedMode
                    + "' is not valid; use 'discover_keep', 'discover_retire' or 'ignore'.";
        } else {
            this.configurationError = null;
        }
        if (configurationError != null) {
            log.error(configurationError);
            this.adapter = null;
            this.adapterConfig = null;
            return;
        }
        log.info("Cloudflare API token received ({} characters, redacted)", token.trim().length());

        this.adapterConfig = AdapterConfig.builder()
                .apiBaseUrl(System.getenv("CLOUDFLARE_API_BASE_URL"))
                .zoneId(zoneId)
                .apiToken(token.trim())
                .csrMode(csrMode)
                .csrSubjectFallback(extendedConfig.getCsrSubjectFallback())
                .renewalStrategy(strategy)
                .certificateType(type)
                .bundleMethod(bundle)
                .csrRetention(retention)
                .managedMode(managedMode)
                .probeBudgetMillis(parseLongOrDefault(System.getenv("CLOUDFLARE_PROBE_BUDGET_MILLIS"),
                        AdapterConfig.DEFAULT_PROBE_BUDGET_MILLIS))
                .build();
        this.adapter = new CloudflareAdapter(adapterConfig);
    }

    /**
     * TLM hands directly-entered plugin secrets over base64-encoded, while a secret injected by a
     * Secrets Manager (PAM) connector may arrive as plain text. Decode when the value is valid
     * base64 <em>and</em> the decoded bytes are printable text; otherwise use the value as-is.
     * Cloudflare API tokens contain {@code _} and {@code -}, which are not base64 characters, so a
     * raw token is used unchanged.
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
            final var replaced = resolveReplacedCertificateId(extended.getCertificateName(), extended.getVirtualServerName());
            final var dnsNames = CertificateAttributesUtil.getDnsNames(csrRequest.getDnsNames());
            log.info("Generating CSR for flow {} (subject [{}], SANs {}, key {}/{}, sig {}, mode {}); will replace custom "
                    + "certificate '{}' at install time", csrRequest.getFlowId(), csrRequest.getSubjectDn(), dnsNames,
                    csrRequest.getKeyAlgorithm(), csrRequest.getKeySize(), csrRequest.getSignatureAlgorithm(),
                    adapterConfig.isCloudflareCsr() ? "cloudflare" : "sensor",
                    replaced == null ? "<none - new certificate>"
                            : CloudflareCertificate.isManagedId(replaced) ? replaced + " (Cloudflare-managed; a new custom certificate will be uploaded)" : replaced);

            final var record = new FlowRecord();
            record.setCsrCreatedAt(OffsetDateTime.now().toString());
            if (adapterConfig.isCloudflareCsr()) {
                final var result = adapter.createCsr(csrRequest.getSubjectDn(), dnsNames, csrRequest.getKeyAlgorithm(),
                        csrRequest.getKeySize());
                if (!result.isSuccess()) {
                    response.setErrors(List.of(new PluginError(result.getErrorCode(), result.getErrorMessage())));
                    log.info("GenerateCsr response (error): {}", objectMapper.writeValueAsString(response));
                    return response;
                }
                record.setKeySource(AdapterConfig.CSR_MODE_CLOUDFLARE);
                record.setCustomCsrId(result.getValue().getCustomCsrId());
                record.setCsrCommonName(result.getValue().getCommonName());
                response.setCsr(result.getValue().getCsr());
            } else {
                final var csr = CloudflareAutomationPluginHelper.generateCsrAndStoreKey(
                        csrRequest.getFlowId(),
                        csrRequest.getSubjectDn(),
                        dnsNames,
                        csrRequest.getKeyAlgorithm(),
                        csrRequest.getKeySize(),
                        csrRequest.getSignatureAlgorithm());
                record.setKeySource(AdapterConfig.CSR_MODE_SENSOR);
                record.setCsrCommonName(CertificateAttributesUtil.getCommonName(csrRequest.getSubjectDn()));
                response.setCsr(csr);
            }
            CloudflareAutomationPluginHelper.writeFlowRecord(csrRequest.getFlowId(), record);
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
                certificates = CloudflareAutomationPluginHelper.splitChainPem(installRequest.getCertificateChain());
            } else if (installRequest.getCertificateLink() != null && !installRequest.getCertificateLink().isBlank()) {
                final Path pluginDir = CloudflareAutomationPluginHelper.flowDirectory(flowId);
                Files.createDirectories(pluginDir);
                final var downloaded = CloudflareAutomationPluginHelper.downloadFileToDirectory(
                        installRequest.getCertificateLink(), pluginDir.toString());
                certificates = CloudflareAutomationPluginHelper.extractCertificates(downloaded);
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
            final var leaf = CloudflareAutomationPluginHelper.parseFirstCertificate(leafPem);
            final var leafCn = CertificateAttributesUtil.getCommonName(leaf.getSubjectX500Principal().getName());
            final var leafSerial = CertificateAttributesUtil.serialHex(leaf);

            // Where is the private key? Cloudflare (CSR id from generateCsr) or the sensor (key file).
            final FlowRecord previous = CloudflareAutomationPluginHelper.readFlowRecord(flowId);
            String customCsrId = previous == null ? null : previous.getCustomCsrId();
            String keyPem = null;
            final boolean sensorKey = CloudflareAutomationPluginHelper.hasStoredPrivateKey(flowId);
            if (customCsrId != null && !customCsrId.isBlank()) {
                log.info("Flow {} uses Cloudflare CSR '{}' (private key held by Cloudflare)", flowId, customCsrId);
            } else if (sensorKey) {
                keyPem = CloudflareAutomationPluginHelper.readStoredPrivateKey(flowId);
                log.info("Flow {} uses a sensor-generated private key", flowId);
            } else {
                throw new WorkflowExecutionException("No Cloudflare CSR id and no sensor private key found for flow '" + flowId
                        + "' at " + CloudflareAutomationPluginHelper.flowDirectory(flowId)
                        + ". generateCsr must run on this sensor before installCertificate.",
                        new IllegalStateException("missing key material"));
            }

            // Certificate file: leaf first; append the ICA for 'force' (Cloudflare needs the chain it
            // should serve) or when explicitly requested.
            final var certFile = new StringBuilder(CloudflareAutomationPluginHelper.normalizePem(leafPem));
            final var ica = certificates.get("ica.cer");
            final boolean appendIca = AdapterConfig.BUNDLE_FORCE.equals(adapterConfig.effectiveBundleMethod()) || extended.isUseCommonIca();
            if (appendIca && ica != null && !ica.isBlank()) {
                certFile.append(CloudflareAutomationPluginHelper.normalizePem(ica));
            } else if (appendIca) {
                log.warn("Bundle method '{}' expects the issuing CA after the leaf, but TLM supplied no ICA - uploading the leaf only",
                        adapterConfig.effectiveBundleMethod());
            }

            // Which certificate is being replaced - a custom one, or a Cloudflare-managed one?
            final var zone = adapter.getZone();
            final var currentCerts = adapter.listCertificates();
            final var managedCerts = adapter.listManagedCertificatesQuietly();
            final List<CloudflareCertificate> inventory = new ArrayList<>(currentCerts);
            inventory.addAll(managedCerts);
            final var endpoints = assignEndpoints(inventory, zone.getName());
            final var selection = ReplacementResolver.resolve(
                    currentCerts,
                    managedCerts,
                    () -> adapter.knownCertificatePems(inventory, zone.getName()),
                    endpoints,
                    extended.getCertificateName(),
                    extended.getVirtualServerName(),
                    installRequest.getCurrentCertificateThumbprint(),
                    firstNonBlank(extended.getIpAddress(), text(request, "ipAddress")),
                    leaf);
            final var replacedIds = selection.ids();
            final var managedIds = selection.managedIds();
            log.info("Installing certificate (CN {}, serial {}, expires {}) into zone '{}' with strategy {}; replacing {} - selected by: {}",
                    leafCn, leafSerial, leaf.getNotAfter().toInstant(), zone.getName(), adapterConfig.effectiveStrategy(),
                    !replacedIds.isEmpty() ? replacedIds : !managedIds.isEmpty() ? managedIds + " (Cloudflare-managed)"
                            : "<nothing - new custom certificate>", selection.strategy());
            if (selection.isEmpty() && (extended.getVirtualServerName() != null
                    || installRequest.getCurrentCertificateThumbprint() != null)) {
                log.warn("TLM asked to replace an existing certificate (alias '{}', thumbprint {}) but none of the custom {} or "
                        + "Cloudflare-managed {} certificates in zone '{}' could be identified as it - a new custom certificate will be uploaded",
                        extended.getVirtualServerName(), installRequest.getCurrentCertificateThumbprint(),
                        currentCerts.stream().map(CloudflareCertificate::getId).toList(),
                        managedCerts.stream().map(CloudflareCertificate::getId).toList(), zone.getName());
            }
            if (!managedIds.isEmpty()) {
                for (String managedId : managedIds) {
                    managedCerts.stream().filter(m -> managedId.equals(m.getId())).findFirst().ifPresent(m ->
                            log.info("Switching {} from the Cloudflare-managed {} certificate '{}' (issuer {}, expires {}) to a custom "
                                    + "certificate; afterwards the managed certificate is {}", m.getHosts(), m.getPackType(), m.packId(),
                                    m.getIssuer(), m.getExpiresOn(), adapterConfig.isManagedRetire()
                                            ? "retired once the custom certificate is active and covers all of its hostnames"
                                            : "kept as fallback (connector setting)"));
                }
            }

            final var installResult = adapter.installCertificate(certFile.toString(), keyPem, customCsrId, leaf, replacedIds);

            final InstallCertificateResponse<JsonNode> response = new InstallCertificateResponse<>();
            if (installResult.isSuccess()) {
                final var installed = installResult.getValue();
                if (customCsrId != null) {
                    final var cn = previous != null && previous.getCsrCommonName() != null ? previous.getCsrCommonName() : leafCn;
                    installed.setCsrsDeleted(adapter.cleanupCsrs(cn, customCsrId, adapterConfig.getCsrRetention()));
                }
                // Hand the hostnames over from the replaced Cloudflare-managed certificate(s), if any.
                adapter.retireManagedCertificates(managedIds, leaf, installed);
                // Persist what validateCertificate needs (fresh JVM per call), then drop the key.
                final var record = previous != null ? previous : new FlowRecord();
                record.setKeySource(customCsrId != null ? AdapterConfig.CSR_MODE_CLOUDFLARE : AdapterConfig.CSR_MODE_SENSOR);
                record.setCustomCsrId(customCsrId);
                record.setInstalledCertificateId(installed.getCertificateId());
                record.setInstalledCertificatePem(CloudflareAutomationPluginHelper.normalizePem(leafPem));
                record.setInstalledSerialNumber(leafSerial);
                record.setInstalledNotAfterEpoch(leaf.getNotAfter().toInstant().getEpochSecond());
                record.setStrategy(adapterConfig.effectiveStrategy());
                record.setReplacedCertificateIds(new ArrayList<>(replacedIds));
                record.setReplacedManagedIds(new ArrayList<>(managedIds));
                record.setPendingManagedRetirements(new ArrayList<>(installed.getPendingManagedRetirements()));
                record.setInstalledAt(OffsetDateTime.now().toString());
                CloudflareAutomationPluginHelper.writeFlowRecord(flowId, record);
                CloudflareAutomationPluginHelper.deleteStoredPrivateKey(flowId);
                log.info("Install complete: id='{}', action={}, status={}, installed serial={}, edge serves={}, deleted={}, retained={}, "
                        + "csrsDeleted={}, managed retired={}, managed retained={}, managed pending={}, universalSslDisabled={}",
                        installed.getCertificateId(), installed.getAction(), installed.getStatus(), leafSerial,
                        installed.getServedSerialNumber() == null ? "<not probed>" : installed.getServedSerialNumber(),
                        installed.getDeletedCertificates(), installed.getRetainedCertificates(), installed.getCsrsDeleted(),
                        installed.getRetiredManaged(), installed.getRetainedManaged(), installed.getPendingManagedRetirements(),
                        installed.isUniversalSslDisabled());
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
            final FlowRecord record = CloudflareAutomationPluginHelper.readFlowRecord(flowId);
            String id = record == null ? null : record.getInstalledCertificateId();
            String expectedSerial = record == null ? null : record.getInstalledSerialNumber();
            final Long expectedNotAfter = record == null ? null : record.getInstalledNotAfterEpoch();
            if (expectedSerial == null || expectedSerial.isBlank()) {
                expectedSerial = firstNonBlank(extended.getCertificateSerialNumber(), text(request, "certificateSerialNumber"));
            }
            if (id == null || id.isBlank()) {
                id = firstNonBlank(extended.getCertificateName(), ReplacementResolver.stripPartition(extended.getVirtualServerName()));
                if (CloudflareCertificate.isManagedId(id)) {
                    // The asset TLM selected was a Cloudflare-managed certificate; what has to be validated is
                    // the custom certificate uploaded in its place, found below by endpoint or serial.
                    log.info("Alias '{}' names a Cloudflare-managed certificate - locating the custom certificate that replaced it", id);
                    id = null;
                }
            }
            final var zone = adapter.getZone();
            if (id == null || id.isBlank()) {
                // No record and no alias: find the certificate by endpoint or by serial on the edge.
                final var certs = adapter.listCertificates();
                final var endpoint = firstNonBlank(extended.getIpAddress(), text(request, "ipAddress"));
                if (endpoint != null) {
                    final var endpoints = assignEndpoints(certs, zone.getName());
                    id = endpoints.entrySet().stream().filter(e -> endpoint.equalsIgnoreCase(e.getValue()))
                            .map(Map.Entry::getKey).findFirst().orElse(null);
                }
                if (id == null && expectedSerial != null) {
                    final var serial = expectedSerial;
                    adapter.knownCertificatePems(certs, zone.getName());
                    id = certs.stream().filter(c -> CertificateAttributesUtil.sameSerial(c.getSerialNumber(), serial))
                            .map(CloudflareCertificate::getId).findFirst().orElse(null);
                }
            }
            final ValidateCertificateResponse<JsonNode> response = new ValidateCertificateResponse<>();
            if (id == null || id.isBlank()) {
                response.setErrors(List.of(new PluginError("CERTIFICATE_VALIDATION_ERROR",
                        "Cannot determine which Cloudflare custom certificate to validate: no flow record for flow '" + flowId
                                + "' and no certificateName / virtualServerName / endpoint / serial in the request")));
                return response;
            }

            final var result = adapter.validateCertificate(id, expectedSerial, expectedNotAfter, zone.getName());
            if (result.isSuccess()) {
                final var entry = result.getValue();
                completePendingManagedRetirements(flowId, record, entry);
                var pem = record == null ? null : record.getInstalledCertificatePem();
                if (pem == null || pem.isBlank()) {
                    pem = entry.getCertificatePem();
                }
                if (pem == null) {
                    log.warn("Certificate '{}' validated in Cloudflare but its PEM is not available to return", id);
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

    /**
     * The install parks the retirement of a replaced Cloudflare-managed certificate while the custom
     * certificate is still {@code pending}; once validation sees it {@code active} the handover is
     * completed here and the flow record updated.
     */
    private void completePendingManagedRetirements(String flowId, FlowRecord record, CloudflareCertificate entry) {
        if (record == null || record.getPendingManagedRetirements() == null || record.getPendingManagedRetirements().isEmpty()) {
            return;
        }
        try {
            final var leaf = record.getInstalledCertificatePem() == null ? null
                    : CloudflareAutomationPluginHelper.parseFirstCertificate(record.getInstalledCertificatePem());
            final var outcome = new com.example.automation.model.CloudflareInstalledCertificate();
            outcome.setCertificateId(entry.getId());
            outcome.setStatus(entry.getStatus());
            log.info("Completing the deferred handover from Cloudflare-managed certificate(s) {} now that '{}' is {}",
                    record.getPendingManagedRetirements(), entry.getId(), entry.getStatus());
            adapter.retireManagedCertificates(new ArrayList<>(record.getPendingManagedRetirements()), leaf, outcome);
            record.setPendingManagedRetirements(new ArrayList<>(outcome.getPendingManagedRetirements()));
            CloudflareAutomationPluginHelper.writeFlowRecord(flowId, record);
            log.info("Deferred handover: retired={}, retained={}, still pending={}, universalSslDisabled={}", outcome.getRetiredManaged(),
                    outcome.getRetainedManaged(), outcome.getPendingManagedRetirements(), outcome.isUniversalSslDisabled());
        } catch (Exception e) {
            log.warn("Deferred handover of Cloudflare-managed certificate(s) {} could not be completed: {}",
                    record.getPendingManagedRetirements(), e.getMessage());
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
                                         CloudflareConfigurationData data) {
        final var certificates = data.allCertificates();
        final var zone = data.getZone();
        final var zoneName = zone != null && zone.getName() != null ? zone.getName() : zoneId;

        // TLM's automation inventory is endpoint-centric and keys endpoints by dataIp:port. Each
        // certificate - custom or Cloudflare-managed - becomes one endpoint named after its primary
        // hostname (what survives a renewal); the alias carries the custom certificate id (or
        // pack-<id> for a managed certificate) so the install knows exactly which certificate to
        // update, replace or hand over from.
        final Map<String, String> endpoints = assignEndpoints(certificates, zoneName);

        final var automationInfo = new RefreshConfigurationResponse.AutomationInfo();
        automationInfo.setManagementIp(zoneName);
        automationInfo.setHostName(zoneName);
        automationInfo.setOsName(CloudflareConfigurationData.OS_NAME);
        automationInfo.setOsFlavor("Cloudflare zone " + zoneName
                + (zone != null && zone.getPlanName() != null ? " (" + zone.getPlanName() + ")" : ""));
        automationInfo.setDataIps(certificates.stream().map(c -> endpoints.get(c.getId())).toArray(String[]::new));
        response.setAutomationInfo(automationInfo);

        response.setDataIpInfo(certificates.stream()
                .map(c -> {
                    final var info = new RefreshConfigurationResponse.DataIpInfo();
                    info.setManagementIp(zoneName);
                    info.setDataIp(endpoints.get(c.getId()));
                    info.setPort(ENDPOINT_PORT);
                    info.setAlias(c.getId());
                    info.setSslState(1);
                    return info;
                })
                .toList());

        response.setCertificates(certificates.stream()
                .map(c -> {
                    final var cert = new RefreshConfigurationResponse.Certificate();
                    final var endpoint = endpoints.get(c.getId());
                    cert.setIpAddress(endpoint);
                    cert.setPort(ENDPOINT_PORT);
                    cert.setIpAndPort(endpoint + ":" + ENDPOINT_PORT);
                    // CN when known, else the primary host, else the id, so the asset is always identifiable.
                    cert.setDomainName(c.getCommonName() != null ? c.getCommonName()
                            : c.primaryHost() != null ? c.primaryHost() : c.getId());
                    // PEM only when it could be fetched from the edge.
                    cert.setCertificate(c.getCertificatePem());
                    cert.setServerParam(c.getId());
                    // Cloudflare reports type (sni_custom / legacy_custom) in practice; SNI unless legacy.
                    // Universal / Advanced certificates are always served by SNI.
                    cert.setSni(c.isManaged() || c.isSni());
                    return cert;
                })
                .toList());
    }

    // ------------------------------------------------------------------ name resolution

    /** Informational at CSR time: explicit {@code certificateName}, else the alias, else null. */
    private static String resolveReplacedCertificateId(String explicit, String virtualServerName) {
        if (explicit != null && !explicit.isBlank()) {
            return explicit.trim();
        }
        return ReplacementResolver.stripPartition(virtualServerName);
    }

    /**
     * Assigns each certificate its discovery endpoint host (certificate id → host).
     *
     * <p>The canonical host is the certificate's primary hostname (CN when listed, else the shortest
     * non-wildcard host, else {@code wildcard.<base>}), e.g. {@code www.example.com}. It does not
     * contain the certificate id, so it stays the same when a renewal uploads a new certificate —
     * TLM keeps tracking a single endpoint. When several certificates share the primary host (an
     * RSA/ECDSA pair, legacy + SNI, a kept predecessor, or a Cloudflare-managed certificate next to
     * the custom one that replaced it), a custom certificate owns the canonical host before a managed
     * one — Cloudflare serves the custom certificate for an equally specific hostname — and among
     * equals the one expiring last; the others fall back to {@code <id prefix>.<host>} so nothing
     * collapses onto one endpoint. A certificate without any host uses {@code cert-<id prefix>.<zone>}.
     */
    static Map<String, String> assignEndpoints(List<CloudflareCertificate> certificates, String zoneName) {
        final Map<String, String> result = new java.util.LinkedHashMap<>();
        final Map<String, List<CloudflareCertificate>> byCanonical = new java.util.LinkedHashMap<>();
        for (CloudflareCertificate c : certificates) {
            final var canonical = c.primaryHost();
            if (canonical == null) {
                result.put(c.getId(), "cert-" + idLabel(c.getId()) + "." + zoneName);
            } else {
                byCanonical.computeIfAbsent(canonical, k -> new ArrayList<>()).add(c);
            }
        }
        for (var entry : byCanonical.entrySet()) {
            final var group = entry.getValue();
            // A custom certificate before a Cloudflare-managed one, then the newest (latest expires_on) owns the stable endpoint.
            group.sort((a, b) -> {
                if (a.isManaged() != b.isManaged()) {
                    return a.isManaged() ? 1 : -1;
                }
                return Long.compare(Objects.requireNonNullElse(b.getExpiresOnEpoch(), 0L),
                        Objects.requireNonNullElse(a.getExpiresOnEpoch(), 0L));
            });
            for (int i = 0; i < group.size(); i++) {
                final var c = group.get(i);
                if (i == 0) {
                    result.put(c.getId(), entry.getKey());
                } else {
                    final var fallback = idLabel(c.getId()) + "." + entry.getKey();
                    result.put(c.getId(), fallback);
                    log.info("Certificate '{}' shares primary host {} with '{}' - reported on endpoint {} instead",
                            c.getId(), entry.getKey(), group.get(0).getId(), fallback);
                }
            }
        }
        result.forEach((id, ep) -> log.info("Endpoint for certificate '{}': {}:{}", id, ep, ENDPOINT_PORT));
        return result;
    }

    /** First 8 characters of the id as a DNS label; {@code pack-<8 chars>} for a Cloudflare-managed certificate. */
    static String idLabel(String id) {
        final boolean managed = CloudflareCertificate.isManagedId(id);
        final var raw = managed ? CloudflareCertificate.stripManagedPrefix(id) : id;
        final var compact = raw == null ? "" : raw.replace("-", "");
        final var label = CertificateAttributesUtil.dnsLabel(compact.length() > 8 ? compact.substring(0, 8) : compact);
        return managed ? "pack-" + label : label;
    }

    private static String blankToDefault(String value, String fallback) {
        return value == null || value.isBlank() ? fallback : value.trim();
    }

    private static long parseLongOrDefault(String value, long fallback) {
        try {
            return value == null || value.isBlank() ? fallback : Long.parseLong(value.trim());
        } catch (NumberFormatException e) {
            return fallback;
        }
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
