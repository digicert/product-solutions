package com.digicert.automation;

import com.digicert.automation.extended.configuration.F5XCPluginConfiguration;
import com.digicert.automation.f5xc.service.InstallCertificateService;
import com.digicert.automation.f5xc.service.RefreshConfigurationService;
import com.digicert.automation.f5xc.service.TestConnectionService;
import com.digicert.automation.f5xc.service.ValidateCertificateService;
import com.digicert.automation.helper.AutomationPluginHelper;
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
import com.digicert.tlm.workflows.automation.dto.RefreshConfigurationResponse;
import com.fasterxml.jackson.core.JsonProcessingException;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import lombok.extern.slf4j.Slf4j;

import java.io.InputStream;
import java.util.List;
import java.util.Optional;

/**
 * DigiCert TLM Automation Plugin for <b>F5 Distributed Cloud (F5-XC)</b>.
 * <p>
 * Manages the lifecycle of F5-XC <em>certificate objects</em>
 * ({@code /api/config/namespaces/{namespace}/certificates}). F5-XC uses a
 * <b>centralized key-generation</b> model: DigiCert generates the key pair, and the
 * plugin uploads both the certificate chain and the private key as a named certificate
 * object. Because of this, {@link #generateCsr(JsonNode)} is intentionally unsupported.
 *
 * @author michael.rudloff
 */
@Slf4j
@WorkflowEntryPoint(name = "F5XCAutomationPlugin")
@SuppressWarnings("unchecked")
public class F5XCAutomationPlugin extends AbstractAutomationWorkflow {

    private F5XCPluginConfiguration pluginConfiguration;

    /**
     * Set when the plugin cannot authenticate with the supplied configuration (for example the PAM
     * connector did not deliver an API token). Every F5-XC-facing lifecycle method fails closed
     * with this message instead of calling the API with an empty credential.
     */
    private String configurationError;

    public F5XCAutomationPlugin(
        SdkContext context,
        PluginConfiguration<F5XCPluginConfiguration> configuration) {
        Optional.ofNullable(configuration.getExtendedConfig()).ifPresent(cfg -> {
            pluginConfiguration = cfg;
            final boolean secretsManager = cfg.isSecretsManagerAuth();
            log.info("------------ Plugin Loaded extended configuration. version : {} ------------", readPluginVersion());
            log.info("Extended configuration: tenant={}, namespace={}, authenticationMethod={}, pamConnectorId={}",
                    cfg.getTenant(),
                    cfg.getNamespace(),
                    secretsManager ? "secrets-manager" : "direct-input",
                    secretsManager ? cfg.getPamConnectorId() : "n/a");
            configurationError = checkApiToken(cfg);
            if (configurationError != null) {
                log.error(configurationError);
            } else {
                log.info("F5-XC API token received ({} characters, redacted)", cfg.getApiToken().length());
            }
        });
    }

    /**
     * Fail closed: never call F5-XC with a missing token. In secrets-manager mode an empty value
     * means the PAM connector could not resolve the vault reference (TLM runs that step before the
     * plugin and injects the result into {@code apiToken}).
     *
     * @return a human-readable error, or {@code null} when the token is usable
     */
    static String checkApiToken(F5XCPluginConfiguration cfg) {
        final String token = cfg.getApiToken();
        if (token != null && !token.isBlank()) {
            return null;
        }
        if (cfg.isSecretsManagerAuth()) {
            return "F5-XC API token was not resolved by the Secrets Manager (PAM) connector"
                    + (cfg.getPamConnectorId() == null ? "" : " '" + cfg.getPamConnectorId() + "'")
                    + ". Check the PAM connector's Test Connection and that the vault reference"
                    + " points at an existing secret the connector is allowed to read.";
        }
        return "F5-XC API token is empty. Re-enter it on the connector, or if the connector uses"
                + " Self-authentication (Secrets manager), check that the PAM connector resolved"
                + " the vault reference.";
    }

    /** Throws the recorded configuration error so a misconfigured connector never reaches F5-XC. */
    private void requireUsableConfiguration() throws WorkflowExecutionException {
        if (configurationError != null) {
            throw new WorkflowExecutionException(configurationError,
                    new IllegalStateException(configurationError));
        }
    }

    private String readPluginVersion() {
        try (InputStream is = F5XCAutomationPlugin.class.getClassLoader()
                .getResourceAsStream("plugin-meta.json")) {
            if (is == null) {
                log.warn("plugin-meta.json not found in classpath");
                return "UNKNOWN";
            }
            JsonNode metaJson = objectMapper.readTree(is);
            String version = metaJson.at("/plugin/version").asText("UNKNOWN");
            log.debug("Read plugin version from plugin-meta.json: {}", version);
            return version;
        } catch (Exception e) {
            log.warn("Failed to read plugin version from plugin-meta.json: {}", e.getMessage());
            return "UNKNOWN";
        }
    }

    public static ObjectMapper getObjectMapper() {
        return objectMapper;
    }

    /**
     * Tests connectivity to the F5-XC API by listing certificate objects in the
     * configured namespace.
     * <p>
     * <b>Sample Request JSON:</b> {@code null}
     * <p>
     * <b>Sample Response JSON:</b>
     * <pre>{ "errors": null, "active": true }</pre>
     */
    @Override
    public Response<JsonNode> testConnection(JsonNode request) throws WorkflowExecutionException {
        log.info("testConnection action started");
        requireUsableConfiguration();
        log(request);
        Response<JsonNode> response = TestConnectionService.getInstance().testConnection(pluginConfiguration);
        log.info("testConnection action completed. isSuccess : {}", isSuccess(response));
        log(response);
        return response;
    }

    /**
     * Generates the key pair and CSR on the sensor (decentralized enrollment) and retains the
     * private key locally, keyed by {@code flowId}, for the subsequent
     * {@link #installCertificate(JsonNode)} call. TLM submits the returned CSR to issue the
     * certificate.
     * <p>
     * <b>Sample Request JSON:</b>
     * <pre>
     * {
     *   "flowId": "8a265aeb-451c-44b7-a1fd-3ec00c98c4e0",
     *   "subjectDn": "CN=f5-xc.digicert-demo.com,O=DigiCert\\, Inc.,C=US",
     *   "dnsNames": "f5-xc.digicert-demo.com",
     *   "keyAlgorithm": "RSA",
     *   "keySize": "2048",
     *   "signatureAlgorithm": "sha256"
     * }
     * </pre>
     * <b>Sample Response JSON:</b>
     * <pre>{ "errors": null, "csr": "-----BEGIN CERTIFICATE REQUEST-----\n...\n-----END CERTIFICATE REQUEST-----\n" }</pre>
     */
    @Override
    public Response<JsonNode> generateCsr(JsonNode request) throws WorkflowExecutionException {
        log.info("generateCsr action started");
        log(request);
        GenerateCsrResponse<JsonNode> response = new GenerateCsrResponse<>();
        try {
            GenerateCsrRequest<JsonNode> csrRequest =
                    PluginUtils.convertWrappedObject(request, GenerateCsrRequest.class);
            String csr = AutomationPluginHelper.generateCsrAndStoreKey(
                    csrRequest.getFlowId(),
                    csrRequest.getSubjectDn(),
                    csrRequest.getKeyAlgorithm(),
                    Integer.parseInt(csrRequest.getKeySize()),
                    csrRequest.getSignatureAlgorithm(),
                    csrRequest.getDnsNames());
            response.setCsr(csr);
        } catch (Exception e) {
            String errorMessage = "Failed to generate CSR. " + e.getMessage();
            log.error(errorMessage, e);
            response.setErrors(List.of(new PluginError("CSR_GENERATION_FAILURE", errorMessage)));
        }
        log.info("generateCsr action completed. isSuccess : {}", isSuccess(response));
        log(response);
        return response;
    }

    /**
     * Uploads the issued certificate (chain) and private key to F5-XC as a named
     * certificate object — creating it (POST) when absent or replacing it (PUT) when present.
     * <p>
     * <b>Sample Request JSON:</b>
     * <pre>
     * {
     *   "flowId": "8a265aeb-451c-44b7-a1fd-3ec00c98c4e0",
     *   "certificateLink": "https://one.digicert.com/mpki/api/v1/ts/artifact/55dc890b-...",
     *   "virtualServerName": "default/f5-xc-digicert-demo"
     * }
     * </pre>
     * The {@code virtualServerName} carries the certificate object name as
     * {@code <namespace>/<certificateName>}; the trailing segment is the F5-XC certificate name.
     */
    @Override
    public Response<JsonNode> installCertificate(JsonNode request) throws WorkflowExecutionException {
        log.info("installCertificate action started");
        requireUsableConfiguration();
        log(request);
        Response<JsonNode> response = InstallCertificateService.getInstance().installCertificate(pluginConfiguration, request);
        log.info("installCertificate action completed. isSuccess : {}", isSuccess(response));
        log(response);
        return response;
    }

    /**
     * Validates the deployed certificate by fetching the F5-XC certificate object and
     * comparing the served certificate's serial number against the expected value.
     * <p>
     * <b>Sample Request JSON:</b>
     * <pre>
     * {
     *   "flowId": "8a265aeb-451c-44b7-a1fd-3ec00c98c4e0",
     *   "certificateSerialNumber": "6a0df325fd660828a86e6c7a8a3e4ecc1a697fcd",
     *   "virtualServerName": "default/f5-xc-digicert-demo"
     * }
     * </pre>
     */
    @Override
    public Response<JsonNode> validateCertificate(JsonNode request) throws WorkflowExecutionException {
        log.info("validateCertificate action started");
        requireUsableConfiguration();
        log(request);
        Response<JsonNode> response = ValidateCertificateService.getInstance().validateCertificate(pluginConfiguration, request);
        log.info("validateCertificate action completed. isSuccess : {}", isSuccess(response));
        log(response);
        return response;
    }

    /**
     * Enumerates F5-XC certificate objects in the configured namespace and returns them
     * as TLM automation info, data-IP info, and certificate details.
     * <p>
     * <b>Sample Request JSON:</b> {@code null}
     */
    @Override
    public Response<JsonNode> refreshConfiguration(JsonNode request) throws WorkflowExecutionException {
        log.info("refreshConfiguration action started");
        requireUsableConfiguration();
        log(request);
        RefreshConfigurationResponse<JsonNode> response = RefreshConfigurationService.getInstance().refreshConfiguration(pluginConfiguration);
        log.info("refreshConfiguration action completed. isSuccess : {}", isSuccess(response));
        log(response);
        return response;
    }

    private boolean isSuccess(Response<JsonNode> response) {
        return response.getErrors() == null || response.getErrors().isEmpty();
    }

    private void log(Object object) {
        try {
            log.info("{}", objectMapper.writeValueAsString(object));
        } catch (JsonProcessingException e) {
            throw new RuntimeException(e);
        }
    }
}
