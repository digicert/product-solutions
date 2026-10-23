package com.example.automation.model;

import java.util.ArrayList;
import java.util.List;

import com.fasterxml.jackson.annotation.JsonIgnoreProperties;

import lombok.Data;

/**
 * State the plugin persists on the sensor between the lifecycle calls of one TLM flow
 * ({@code <java.io.tmpdir>/CloudflareAutomationPlugin/<flowId>/flow.json}). Every plugin call runs
 * in a fresh JVM, so anything {@code generateCsr} must hand to {@code installCertificate} (the
 * Cloudflare CSR id) and {@code installCertificate} to {@code validateCertificate} (the custom
 * certificate id and the expected expiry) has to go through this file. A sensor-generated private
 * key is kept in a separate file and deleted as soon as the install completes.
 */
@Data
@JsonIgnoreProperties(ignoreUnknown = true)
public class FlowRecord {

    /** {@code cloudflare} when Cloudflare generated the key/CSR, {@code sensor} otherwise. */
    private String keySource;

    /** Id of the Cloudflare custom CSR created during generateCsr (Cloudflare key mode). */
    private String customCsrId;

    /** Common name the CSR was created for (used for CSR clean-up). */
    private String csrCommonName;

    /** Id of the Cloudflare custom certificate that carries the installed certificate. */
    private String installedCertificateId;

    /** PEM of the installed end-entity certificate (returned by validateCertificate). */
    private String installedCertificatePem;

    /** Upper-case hex serial of the installed end-entity certificate. */
    private String installedSerialNumber;

    /** notAfter of the installed end-entity certificate as epoch seconds (Cloudflare reports it as expires_on). */
    private Long installedNotAfterEpoch;

    /** Which strategy was applied: update / replace_delete / replace_keep. */
    private String strategy;

    /** The previous custom certificate id(s) this flow replaced, for traceability. */
    private List<String> replacedCertificateIds = new ArrayList<>();

    /** ISO-8601 timestamp of the CSR creation. */
    private String csrCreatedAt;

    /** ISO-8601 timestamp of the install. */
    private String installedAt;
}
