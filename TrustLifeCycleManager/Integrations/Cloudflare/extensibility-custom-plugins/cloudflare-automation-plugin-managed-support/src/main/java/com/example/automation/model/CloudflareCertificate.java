package com.example.automation.model;

import java.util.ArrayList;
import java.util.List;
import java.util.Locale;

import lombok.Data;

/**
 * One edge certificate of a Cloudflare zone as TLM sees it. Two kinds share this model:
 * <ul>
 *   <li><b>custom certificates</b> ({@code GET /zones/{zone_id}/custom_certificates}) — uploaded by
 *       the customer, the only kind TLM can renew;</li>
 *   <li><b>Cloudflare-managed certificates</b> ({@code GET /zones/{zone_id}/ssl/certificate_packs}
 *       of type {@code universal}, {@code advanced} or {@code total_tls}) — issued by Cloudflare
 *       through Google Trust Services, Let's Encrypt or SSL.com. They are surfaced ({@link #managed}
 *       = true, id prefixed with {@link #MANAGED_ID_PREFIX}) so an operator can pick one in TLM and
 *       replace it with a custom (DigiCert) certificate.</li>
 * </ul>
 * Cloudflare reports metadata only — hosts, issuer, signature algorithm, status, validity — but never
 * the certificate body. When the plugin manages to fetch the body (TLS handshake against the
 * Cloudflare edge, see {@code CloudflareAdapter.tryFetchCertificatePem}) the X.509 fields are
 * parsed from it and take precedence.
 */
@Data
public class CloudflareCertificate {

    /** Prefix of the asset id / alias under which a Cloudflare-managed certificate pack is surfaced. */
    public static final String MANAGED_ID_PREFIX = "pack-";

    public static final String PACK_UNIVERSAL = "universal";
    public static final String PACK_ADVANCED = "advanced";
    public static final String PACK_TOTAL_TLS = "total_tls";

    /** Custom certificate id (UUID), or {@code pack-<pack id>} for a Cloudflare-managed certificate. */
    private String id;
    private String zoneId;

    /** Hostnames the certificate covers, as Cloudflare lists them (may include wildcards). */
    private List<String> hosts = new ArrayList<>();

    /** Issuer as Cloudflare prints it (organisation, e.g. {@code DigiCert}). */
    private String issuer;

    /** Signature algorithm as Cloudflare prints it, e.g. {@code SHA256WithRSA}. */
    private String signature;

    /** {@code active}, {@code pending}, {@code initializing}, {@code expired} or {@code deleted}; packs have more states. */
    private String status;

    /** {@code ubiquitous}, {@code optimal} or {@code force}. */
    private String bundleMethod;

    /**
     * {@code sni_custom} or {@code legacy_custom} for custom certificates (not in Cloudflare's
     * published schema but returned in practice); the pack type for managed certificates.
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

    // ---- Cloudflare-managed certificate packs only ----

    /** True for a Cloudflare-managed edge certificate (Universal SSL / Advanced Certificate Manager pack). */
    private boolean managed;

    /** {@link #PACK_UNIVERSAL}, {@link #PACK_ADVANCED} or {@link #PACK_TOTAL_TLS}. */
    private String packType;

    /** CA Cloudflare issued the pack through: {@code google}, {@code lets_encrypt} or {@code ssl_com}. */
    private String certificateAuthority;

    /**
     * {@code expires_on} of every certificate inside the pack. A Universal pack can carry an ECDSA
     * and an RSA certificate with different expiries; the edge may serve either one.
     */
    private List<Long> packExpiresOnEpochs = new ArrayList<>();

    private String validationMethod;
    private Integer validityDays;

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

    /** True for a Universal SSL pack (retired by disabling Universal SSL, not by deleting the pack). */
    public boolean isUniversal() {
        return managed && packType != null && PACK_UNIVERSAL.equalsIgnoreCase(packType.trim());
    }

    /** The raw Cloudflare certificate-pack id (without the {@link #MANAGED_ID_PREFIX}); null for a custom certificate. */
    public String packId() {
        return managed ? stripManagedPrefix(id) : null;
    }

    /** Human-readable kind for log lines: {@code custom}, or e.g. {@code universal (Cloudflare-managed, google)}. */
    public String kind() {
        if (!managed) {
            return "custom";
        }
        return (packType == null ? "managed" : packType.toLowerCase(Locale.ROOT)) + " (Cloudflare-managed"
                + (certificateAuthority == null ? "" : ", " + certificateAuthority) + ")";
    }

    /** True when {@code notAfterEpoch} equals this certificate's expiry (or one of the pack's certificates') within a second. */
    public boolean matchesExpiry(long notAfterEpoch) {
        if (expiresOnEpoch != null && Math.abs(expiresOnEpoch - notAfterEpoch) <= 1) {
            return true;
        }
        for (Long e : packExpiresOnEpochs) {
            if (e != null && Math.abs(e - notAfterEpoch) <= 1) {
                return true;
            }
        }
        return false;
    }

    /** True when the certificate carries any expiry information. */
    public boolean hasExpiry() {
        return expiresOnEpoch != null || !packExpiresOnEpochs.isEmpty();
    }

    public static boolean isManagedId(String id) {
        return id != null && id.trim().toLowerCase(Locale.ROOT).startsWith(MANAGED_ID_PREFIX);
    }

    /** {@code pack-<id>} → {@code <id>}; other values are returned trimmed. */
    public static String stripManagedPrefix(String id) {
        if (id == null) {
            return null;
        }
        final var t = id.trim();
        return isManagedId(t) ? t.substring(MANAGED_ID_PREFIX.length()) : t;
    }

    public static String managedId(String packId) {
        return packId == null ? null : MANAGED_ID_PREFIX + packId.trim();
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
