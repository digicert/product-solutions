package com.example.automation.model;

import com.fasterxml.jackson.annotation.JsonIgnoreProperties;

import lombok.Data;

/**
 * State the plugin persists on the sensor between the lifecycle calls of one TLM flow
 * ({@code <java.io.tmpdir>/FortiGateAutomationPlugin/<flowId>/flow.json}). Every plugin call runs in
 * a fresh JVM, so anything {@code installCertificate} must hand to {@code validateCertificate} —
 * chiefly the name FortiGate stored the new certificate under — has to go through this file.
 * The private key is kept in a separate file and deleted as soon as the install completes.
 */
@Data
@JsonIgnoreProperties(ignoreUnknown = true)
public class FlowRecord {

    /** Name the renewed certificate was imported under on FortiGate. */
    private String installedCertificateName;

    /** PEM of the installed end-entity certificate (returned by validateCertificate). */
    private String installedCertificatePem;

    /** Upper-case hex serial of the installed end-entity certificate. */
    private String installedSerialNumber;

    /** The previous certificate name(s) this flow replaced, for traceability. */
    private java.util.List<String> replacedCertificateNames = new java.util.ArrayList<>();

    /** ISO-8601 timestamp of the install. */
    private String installedAt;
}
