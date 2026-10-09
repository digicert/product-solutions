package com.example.automation.model;

import lombok.Data;

/**
 * Outcome of a successful {@code installCertificate}: the name FortiGate stored the renewed
 * certificate under, the leaf PEM that was uploaded, and a summary of the rotation performed.
 */
@Data
public class FortiGateInstalledCertificate {

    /** Name of the newly imported local certificate on FortiGate. */
    private String certificateName;

    /** PEM of the uploaded end-entity certificate. */
    private String certificate;

    /** Upper-case hex serial of the uploaded end-entity certificate. */
    private String serialNumber;

    /** Number of references (policy / SNI / multi-cert) repointed to the new certificate. */
    private int referencesRepointed;

    /** Names of the previous certificates that were deleted after rotation. */
    private java.util.List<String> deletedCertificates = new java.util.ArrayList<>();

    /** Names of the previous certificates intentionally left in place (kept or still referenced). */
    private java.util.List<String> retainedCertificates = new java.util.ArrayList<>();
}
