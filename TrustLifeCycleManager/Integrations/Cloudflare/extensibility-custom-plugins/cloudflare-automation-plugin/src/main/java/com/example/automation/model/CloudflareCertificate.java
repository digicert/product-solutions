package com.example.automation.model;

import java.util.ArrayList;
import java.util.List;
import java.util.Locale;

import lombok.Data;

/**
 * One custom certificate in a Cloudflare zone, as listed by
 * {@code GET /zones/{zone_id}/custom_certificates}. Cloudflare reports metadata only — hosts,
 * issuer, signature algorithm, status, validity, priority, the CSR it was created from — but never
 * the certificate body. When the plugin manages to fetch the body (TLS handshake against the
 * Cloudflare edge, see {@code CloudflareAdapter.tryFetchCertificatePem}) the X.509 fields are
 * parsed from it and take precedence.
 */
@Data
public class CloudflareCertificate {

    /** Custom certificate id (UUID); what SSL settings and TLM aliases refer to. */
    private String id;
    private String zoneId;

    /** Hostnames the certificate covers, as Cloudflare lists them (may include wildcards). */
    private List<String> hosts = new ArrayList<>();

    /** Issuer as Cloudflare prints it (organisation, e.g. {@code DigiCert}). */
    private String issuer;

    /** Signature algorithm as Cloudflare prints it, e.g. {@code SHA256WithRSA}. */
    private String signature;

    /** {@code active}, {@code pending}, {@code initializing}, {@code expired} or {@code deleted}. */
    private String status;

    /** {@code ubiquitous}, {@code optimal} or {@code force}. */
    private String bundleMethod;

    /**
     * {@code sni_custom} or {@code legacy_custom}. Not in Cloudflare's published schema but returned
     * in practice (seen 2026-10-12); null when absent.
     */
    private String type;

    private Integer priority;

    /** Id of the Cloudflare custom CSR the certificate was created from, when any. */
    private String customCsrId;

    /** Validity end as Cloudflare prints it (ISO-8601). */
    private String expiresOn;

    /** {@link #expiresOn} as epoch seconds when parseable; null otherwise. */
    private Long expiresOnEpoch;

    private String uploadedOn;
    private String modifiedOn;

    // ---- derived from the PEM when it could be fetched ----

    /** PEM of the certificate when it could be obtained from the Cloudflare edge; null otherwise. */
    private String certificatePem;
    private String subject;
    private String issuerDn;
    private String commonName;
    private String serialNumber;
    private String keyType;
    private Integer keySize;
    private String validFrom;
    private String validTo;
    /** Upper-case hex SHA-256 fingerprint of the DER encoding (no separators), when the PEM is known. */
    private String fingerprintSha256;

    /** @return true for {@code active} (the only state in which the edge serves the certificate). */
    public boolean isActive() {
        return status != null && "active".equalsIgnoreCase(status.trim());
    }

    /** True unless Cloudflare reports the certificate as {@code legacy_custom}. */
    public boolean isSni() {
        return type == null || !"legacy_custom".equalsIgnoreCase(type.trim());
    }

    public boolean isDeleted() {
        return status != null && "deleted".equalsIgnoreCase(status.trim());
    }

    public List<String> nonWildcardHosts() {
        final List<String> result = new ArrayList<>();
        for (String h : hosts) {
            if (h != null && !h.isBlank() && !h.startsWith("*")) {
                result.add(h.trim().toLowerCase(Locale.ROOT));
            }
        }
        return result;
    }

    public List<String> wildcardHosts() {
        final List<String> result = new ArrayList<>();
        for (String h : hosts) {
            if (h != null && h.startsWith("*")) {
                result.add(h.trim().toLowerCase(Locale.ROOT));
            }
        }
        return result;
    }

    /**
     * The hostname that identifies this certificate in TLM: the CN when it is one of the hosts,
     * else the shortest non-wildcard host, else {@code wildcard.<base>} for a wildcard-only
     * certificate, else null when Cloudflare listed no hosts at all.
     */
    public String primaryHost() {
        final var plain = nonWildcardHosts();
        if (commonName != null) {
            final var cn = commonName.trim().toLowerCase(Locale.ROOT);
            if (plain.contains(cn)) {
                return cn;
            }
        }
        if (!plain.isEmpty()) {
            String best = plain.get(0);
            for (String h : plain) {
                if (h.length() < best.length()) {
                    best = h;
                }
            }
            return best;
        }
        final var wild = wildcardHosts();
        if (!wild.isEmpty()) {
            return "wildcard." + wild.get(0).substring(2);
        }
        return null;
    }
}
