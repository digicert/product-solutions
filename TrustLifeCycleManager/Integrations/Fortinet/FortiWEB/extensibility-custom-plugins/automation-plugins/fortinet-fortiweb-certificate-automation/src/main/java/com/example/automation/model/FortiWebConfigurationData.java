package com.example.automation.model;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

import lombok.Data;

/**
 * Aggregated inventory pulled from a FortiWeb appliance during {@code refreshConfiguration}: the
 * appliance itself, every local certificate it holds, and where each certificate is referenced
 * (server policy / SNI member / multi-cert group). Each certificate is a discoverable asset a
 * customer can select in TLM; selecting one drives the "replace this certificate" flow.
 */
@Data
public class FortiWebConfigurationData {

    /** Marks the endpoint OS name in the TLM inventory. */
    public static final String OS_NAME = "FORTIWEB";

    /** FortiWeb management host (FQDN or IP) as configured on the connector. */
    private String host;

    /** FortiWeb REST API port as configured on the connector. */
    private int port;

    private List<FortiWebCertificate> certificates = new ArrayList<>();

    /** Certificate name → every reference found on the appliance (empty list = unused). */
    private Map<String, List<CertificateReference>> references = new LinkedHashMap<>();

    public List<CertificateReference> referencesOf(String certificateName) {
        return references.getOrDefault(certificateName, List.of());
    }
}
