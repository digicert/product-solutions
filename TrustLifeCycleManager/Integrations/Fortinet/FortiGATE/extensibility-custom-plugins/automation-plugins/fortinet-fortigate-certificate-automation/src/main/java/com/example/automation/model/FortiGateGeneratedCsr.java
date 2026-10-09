package com.example.automation.model;

import java.util.List;

import lombok.Data;

/**
 * The PEM-encoded PKCS#10 CSR produced on the TLM sensor during {@code generateCsr}. FortiGate has
 * no API to sign an externally issued certificate against an appliance-generated CSR in a way TLM
 * can drive, so the plugin generates the key pair itself, keeps the private key on the sensor
 * (scoped to the TLM flow) and uploads certificate + key together during {@code installCertificate}.
 */
@Data
public class FortiGateGeneratedCsr {
    private String csr;
    private List<String> warnings;
}
