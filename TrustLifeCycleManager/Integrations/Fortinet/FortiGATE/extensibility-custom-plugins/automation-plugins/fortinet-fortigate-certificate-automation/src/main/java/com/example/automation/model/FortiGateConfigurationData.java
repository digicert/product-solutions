package com.example.automation.model;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

import lombok.Data;

/**
 * Aggregated inventory pulled from a FortiGate during {@code refreshConfiguration}: the appliance
 * itself, every local certificate in the managed scope, and where each certificate is referenced
 * (SSL-VPN, admin HTTPS, IPsec tunnels, VIPs, …). Each certificate is a discoverable asset a
 * customer can select in TLM; selecting one drives the "replace this certificate" flow.
 */
@Data
public class FortiGateConfigurationData {

    /** Marks the endpoint OS name in the TLM inventory. */
    public static final String OS_NAME = "FORTIGATE";

    /** FortiGate management host (FQDN or IP) as configured on the connector. */
    private String host;

    /** FortiGate REST API port as configured on the connector. */
    private int port;

    /** FortiOS version string reported by {@code monitor/system/status}, when available. */
    private String version;

    private List<FortiGateCertificate> certificates = new ArrayList<>();

    /** Certificate name → every reference found on the appliance (empty list = unused). */
    private Map<String, List<CertificateReference>> references = new LinkedHashMap<>();

    public List<CertificateReference> referencesOf(String certificateName) {
        return references.getOrDefault(certificateName, List.of());
    }
}
