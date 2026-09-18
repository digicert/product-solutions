package com.digicert.automation.f5xc.service;

import com.digicert.automation.extended.configuration.F5XCPluginConfiguration;
import com.digicert.automation.f5xc.service.api.F5XCApiAdapter;
import com.digicert.automation.f5xc.service.api.response.CertificateObject;
import com.digicert.automation.helper.AutomationPluginHelper;
import com.digicert.tlm.plugin.PluginError;
import com.digicert.tlm.plugin.Response;
import com.digicert.tlm.workflows.automation.dto.ValidateCertificateResponse;
import com.fasterxml.jackson.databind.JsonNode;
import lombok.extern.slf4j.Slf4j;

import java.math.BigInteger;
import java.security.cert.X509Certificate;
import java.util.List;

/**
 * Validates the deployed certificate by fetching the F5-XC certificate object and comparing
 * the served certificate's serial number against the expected value from the request.
 * <p>
 * F5-XC may take a moment to publish a freshly uploaded certificate, so the check is retried.
 *
 * @author michael.rudloff
 */
@Slf4j
public final class ValidateCertificateService {

    private static final int MAX_ATTEMPTS = 3;

    private ValidateCertificateService() {
    }

    private static final class SingletonHolder {
        private static final ValidateCertificateService INSTANCE = new ValidateCertificateService();
    }

    public static ValidateCertificateService getInstance() {
        return SingletonHolder.INSTANCE;
    }

    /** Overridable in tests to avoid real wall-clock delays. */
    private Runnable sleeper = () -> {
        try {
            Thread.sleep(5_000L);
        } catch (InterruptedException ie) {
            Thread.currentThread().interrupt();
        }
    };

    /** For testing only – replaces the retry sleep with a no-op (or custom delay). */
    public void setSleeper(Runnable sleeper) {
        this.sleeper = sleeper;
    }

    public Response<JsonNode> validateCertificate(F5XCPluginConfiguration pluginConfiguration, JsonNode request) {
        ValidateCertificateResponse<JsonNode> response = new ValidateCertificateResponse<>();
        try {
            String certificateName = ServiceSupport.certificateNameFrom(request);
            String expectedSerial = ServiceSupport.text(request, "certificateSerialNumber");

            Exception lastError = null;
            for (int attempt = 1; attempt <= MAX_ATTEMPTS; attempt++) {
                try {
                    log.info("Attempt {}: validating certificate object '{}' in namespace '{}'",
                            attempt, certificateName, pluginConfiguration.getNamespace());
                    String pem = fetchCertificatePem(pluginConfiguration, certificateName);
                    verifySerial(pem, expectedSerial);
                    response.setCertificate(pem);
                    log.info("Certificate validation successful");
                    return response;
                } catch (Exception e) {
                    lastError = e;
                    log.warn("Attempt {}: validation failed for '{}': {}", attempt, certificateName, e.getMessage());
                    if (attempt < MAX_ATTEMPTS) {
                        log.info("Retrying after delay...");
                        sleeper.run();
                    }
                }
            }
            throw lastError;
        } catch (Exception e) {
            String errorMessage = "Failed to validate certificate through F5-XC API. " + e.getMessage();
            log.error(errorMessage, e);
            response.setErrors(List.of(new PluginError("VALIDATE_CERTIFICATE_FAILURE", errorMessage)));
        }
        return response;
    }

    private String fetchCertificatePem(F5XCPluginConfiguration configuration, String certificateName) throws Exception {
        CertificateObject object = F5XCApiAdapter.getInstance().getCertificate(configuration, certificateName);
        String pem = object.getSpec() == null ? "" : AutomationPluginHelper.decodeF5XCCertificateUrl(object.getSpec().getCertificateUrl());
        if (pem.isBlank()) {
            throw new IllegalStateException("Certificate object '" + certificateName + "' has no inline certificate_url");
        }
        return pem;
    }

    private void verifySerial(String pem, String expectedSerial) throws Exception {
        if (expectedSerial == null || expectedSerial.isBlank()) {
            return; // nothing to compare against
        }
        X509Certificate x509 = AutomationPluginHelper.parseFirstCertificate(pem);
        BigInteger actual = x509.getSerialNumber();

        String expectedHex = expectedSerial.replace(":", "").trim();
        BigInteger expected;
        try {
            expected = new BigInteger(expectedHex, 16);
        } catch (NumberFormatException nfe) {
            throw new IllegalStateException("Invalid expected certificate serial number: " + expectedSerial, nfe);
        }

        // Compare numerically so differences in case (3F vs 3f) and leading zeros (the DER
        // serial may carry a leading 00/0-nibble that BigInteger.toString(16) drops) don't matter.
        if (!actual.equals(expected)) {
            throw new IllegalStateException(String.format(
                    "Certificate serial number mismatch. Expected: %s, Found: %s. There may be a delay before "
                            + "F5-XC publishes the latest certificate; check again shortly.",
                    expectedHex, AutomationPluginHelper.getSerialNumberHex(x509)));
        }
    }
}
