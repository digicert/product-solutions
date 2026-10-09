package com.example.automation.model;

import java.util.Locale;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

import lombok.Data;

/**
 * One local certificate on a FortiGate, merged from two FortiOS REST views:
 * <ul>
 *   <li>{@code GET /api/v2/monitor/system/available-certificates} — rich metadata (subject/issuer,
 *       validity, serial, key type/size, source, status, built-in / default flags);</li>
 *   <li>{@code GET /api/v2/cmdb/vpn.certificate/local?with_meta=1} — the configuration object:
 *       {@code range} (global/vdom), {@code source}, the reference count {@code q_ref} and, on the
 *       firmware validated so far, the PEM itself in the {@code certificate} attribute (the
 *       {@code private-key} attribute is returned encrypted and is never used).</li>
 * </ul>
 * When the PEM is available the X.509 fields are taken from it (authoritative); the monitor view
 * only fills the gaps.
 */
@Data
public class FortiGateCertificate {

    private static final Pattern CN_PATTERN = Pattern.compile("CN\\s*=\\s*([^,/]+)", Pattern.CASE_INSENSITIVE);

    /** FortiOS object name (the {@code mkey}); this is what SSL-VPN / IPsec / VIP objects reference. */
    private String name;

    /** {@code user} (imported) or {@code factory} (built-in, cannot be deleted). */
    private String source;

    /** {@code global} or {@code vdom}. */
    private String range;

    /** Key algorithm label: {@code rsa}, {@code ecc}, {@code dsa} or null when unknown. */
    private String keyType;
    private Integer keySize;

    /** Monitor status string, e.g. {@code valid} / {@code expired}. */
    private String status;

    private String issuer;
    private String subject;
    private String commonName;
    private String validFrom;
    private String validTo;

    /** {@link #validTo} as epoch seconds when known (used to order same-CN duplicates); null otherwise. */
    private Long validToEpoch;

    /** Serial as hex (may carry colons/spaces as FortiOS prints it). */
    private String serialNumber;

    /** Reference count ({@code q_ref}) when FortiOS reported it; null when unknown. */
    private Integer refCount;

    private Boolean builtIn;
    private Boolean defaultLocal;

    /** True for a CA certificate ({@code type: local-ca} / {@code is_ca}); never a TLS server certificate to renew. */
    private Boolean ca;

    /** Upper-case hex SHA-256 fingerprint as reported by the monitor view (no separators), or null. */
    private String fingerprintSha256;

    /** PEM of the certificate when it could be obtained (cmdb attribute, download, CLI or TLS); null otherwise. */
    private String certificatePem;

    /** @return the CN — parsed from the PEM/monitor subject, or extracted from a textual subject. */
    public String getCommonName() {
        if (commonName != null && !commonName.isBlank()) {
            return commonName;
        }
        if (subject == null) {
            return null;
        }
        final Matcher m = CN_PATTERN.matcher(subject);
        return m.find() ? m.group(1).trim() : null;
    }

    /** @return true when issuer and subject are identical (a self-signed certificate). */
    public boolean isSelfSigned() {
        return issuer != null && subject != null && issuer.trim().equalsIgnoreCase(subject.trim());
    }

    /** @return true for FortiOS built-in certificates ({@code Fortinet_Factory}, {@code Fortinet_SSL}, …). */
    public boolean isFactory() {
        return Boolean.TRUE.equals(builtIn)
                || (source != null && source.trim().toLowerCase(Locale.ROOT).startsWith("factory"));
    }

    public boolean isCaCertificate() {
        return Boolean.TRUE.equals(ca);
    }

    /** @return true when FortiOS reported the certificate as referenced by at least one object. */
    public boolean isKnownReferenced() {
        return refCount != null && refCount > 0;
    }

    /** Normalises FortiOS key-type spellings ({@code RSA}, {@code EC}, {@code ECDSA}, {@code DSA}) to a short label. */
    public static String keyTypeLabel(String raw) {
        if (raw == null || raw.isBlank()) {
            return null;
        }
        final var v = raw.trim().toUpperCase(Locale.ROOT);
        if (v.startsWith("RSA")) {
            return "rsa";
        }
        if (v.startsWith("EC")) {
            return "ecc";
        }
        if (v.startsWith("DSA")) {
            return "dsa";
        }
        return v.toLowerCase(Locale.ROOT);
    }
}
