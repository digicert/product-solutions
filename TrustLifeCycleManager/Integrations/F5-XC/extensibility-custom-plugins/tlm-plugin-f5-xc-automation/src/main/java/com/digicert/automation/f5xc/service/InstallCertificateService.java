package com.digicert.automation.f5xc.service;

import com.digicert.automation.extended.configuration.F5XCPluginConfiguration;
import com.digicert.automation.f5xc.service.api.DigiCertApiAdapter;
import com.digicert.automation.f5xc.service.api.F5XCApiAdapter;
import com.digicert.automation.helper.AutomationPluginHelper;
import com.digicert.tlm.plugin.PluginError;
import com.digicert.tlm.plugin.PluginUtils;
import com.digicert.tlm.plugin.Response;
import com.digicert.tlm.workflows.automation.dto.InstallCertificateRequest;
import com.digicert.tlm.workflows.automation.dto.InstallCertificateResponse;
import com.fasterxml.jackson.databind.JsonNode;
import lombok.extern.slf4j.Slf4j;

import java.nio.charset.StandardCharsets;
import java.util.Base64;
import java.util.List;

/**
 * Installs the issued certificate into F5-XC by upserting a named certificate object.
 * <p>
 * F5-XC uses decentralized enrollment: the sensor generated the key pair and CSR in
 * {@code generateCsr} and retained the private key locally (keyed by {@code flowId}). Here we
 * download the issued certificate chain, pair it with that retained key, and create (POST) or
 * replace (PUT) the certificate object of the same name — which renews/overwrites the existing
 * certificate in place.
 *
 * @author michael.rudloff
 */
@Slf4j
public final class InstallCertificateService {

    private InstallCertificateService() {
    }

    private static final class SingletonHolder {
        private static final InstallCertificateService INSTANCE = new InstallCertificateService();
    }

    public static InstallCertificateService getInstance() {
        return SingletonHolder.INSTANCE;
    }

    public Response<JsonNode> installCertificate(F5XCPluginConfiguration pluginConfiguration, JsonNode request) {
        InstallCertificateResponse<JsonNode> response = new InstallCertificateResponse<>();
        String tempDirectory = null;
        String flowId = null;
        try {
            InstallCertificateRequest<JsonNode> installRequest =
                    PluginUtils.convertWrappedObject(request, InstallCertificateRequest.class);
            flowId = installRequest.getFlowId();
            String certificateName = ServiceSupport.certificateNameFrom(request);
            log.info("Installing certificate object '{}' in namespace '{}' (flow '{}')",
                    certificateName, pluginConfiguration.getNamespace(), flowId);

            // Issued certificate chain comes from DigiCert; the private key is the one the sensor
            // generated in generateCsr and retained locally for this flow.
            tempDirectory = AutomationPluginHelper.createTempDirectory();
            String artifactLocation = DigiCertApiAdapter.getInstance()
                    .downloadArtifact(installRequest.getCertificateLink(), tempDirectory);

            String certificateChainPem = AutomationPluginHelper.extractCertificateChain(artifactLocation);
            String privateKeyPem = AutomationPluginHelper.readStoredPrivateKey(flowId);

            String certBase64 = base64(certificateChainPem);
            String keyBase64 = base64(privateKeyPem);

            F5XCApiAdapter.getInstance().upsertCertificate(pluginConfiguration, certificateName, certBase64, keyBase64);
            log.info("install certificate successful");
        } catch (Exception e) {
            String errorMessage = "Failed to install certificate through F5-XC API. " + e.getMessage();
            log.error(errorMessage, e);
            response.setErrors(List.of(new PluginError("CERTIFICATE_INSTALLATION_FAILURE", errorMessage)));
        } finally {
            AutomationPluginHelper.deleteTempDirectory(tempDirectory);
            AutomationPluginHelper.deleteFlowDirectory(flowId);
        }
        return response;
    }

    private static String base64(String value) {
        return Base64.getEncoder().encodeToString(value.getBytes(StandardCharsets.UTF_8));
    }
}
