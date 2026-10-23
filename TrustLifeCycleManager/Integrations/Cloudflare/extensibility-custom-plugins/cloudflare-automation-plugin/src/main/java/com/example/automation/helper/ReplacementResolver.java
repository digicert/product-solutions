package com.example.automation.helper;

import java.security.cert.X509Certificate;
import java.util.ArrayList;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Objects;
import java.util.Set;
import java.util.function.Supplier;

import com.example.automation.model.CloudflareCertificate;

import lombok.extern.slf4j.Slf4j;

/**
 * Decides which Cloudflare custom certificate(s) an install replaces.
 *
 * <p>TLM identifies the certificate being renewed in several, not always consistent, ways: the
 * asset alias round-tripped in {@code virtualServerName} (the custom certificate id), the SHA-256
 * thumbprint of the certificate it last saw ({@code currentCertificateThumbprint}), and the
 * endpoint ({@code ipAddress}) the request is for. With the <em>update in place</em> strategy the
 * id never changes, so the alias is normally enough; after a <em>replace</em> the alias is stale.
 * This resolver therefore tries, in order, and only accepts an id that exists in the zone:
 * <ol>
 *   <li>an explicit {@code certificateName} override,</li>
 *   <li>the round-tripped alias,</li>
 *   <li>the thumbprint, matched against the certificate bodies fetched from the edge,</li>
 *   <li>the endpoint: the certificate whose discovery endpoint equals the request's {@code ipAddress},</li>
 *   <li>host coverage: certificates whose {@code hosts} cover the new leaf's CN or one of its SAN
 *       DNS names (same key algorithm when the body is known — an RSA renewal never selects an
 *       ECDSA certificate), newest first.</li>
 * </ol>
 */
@Slf4j
public final class ReplacementResolver {

    private ReplacementResolver() {
    }

    /** Ids to rotate out plus a human-readable description of how they were chosen. */
    public record Selection(List<String> ids, String strategy) {
        public static Selection none(String reason) {
            return new Selection(List.of(), reason);
        }
        public boolean isEmpty() {
            return ids.isEmpty();
        }
    }

    /**
     * @param certificates      current custom certificates of the zone
     * @param pems              lazily fetched id → PEM (only consulted for thumbprint matching)
     * @param endpointById      certificate id → discovery endpoint host
     * @param explicit          {@code certificateName} from the request, may be null
     * @param virtualServerName {@code <partition>/<alias>} from the request, may be null
     * @param thumbprint        {@code currentCertificateThumbprint} from the request, may be null
     * @param ipAddress         endpoint host from the request, may be null
     * @param leaf              the newly issued certificate
     */
    public static Selection resolve(List<CloudflareCertificate> certificates, Supplier<Map<String, String>> pems,
                                    Map<String, String> endpointById, String explicit, String virtualServerName,
                                    String thumbprint, String ipAddress, X509Certificate leaf) {
        final Set<String> present = new LinkedHashSet<>();
        certificates.forEach(c -> present.add(c.getId()));

        // 1. explicit override
        if (explicit != null && !explicit.isBlank()) {
            if (present.contains(explicit.trim())) {
                return new Selection(List.of(explicit.trim()), "explicit certificateName");
            }
            log.warn("certificateName '{}' is not a custom certificate of this zone - ignoring the override", explicit);
        }

        // 2. round-tripped alias
        final var alias = stripPartition(virtualServerName);
        if (alias != null) {
            if (present.contains(alias)) {
                return new Selection(List.of(alias), "asset alias round-tripped by TLM (virtualServerName)");
            }
            log.warn("TLM round-tripped alias '{}' but no such custom certificate exists in the zone (stale alias after "
                    + "an earlier replace?) - falling back to thumbprint / endpoint / host matching", alias);
        }

        // 3. thumbprint against known bodies
        if (thumbprint != null && !thumbprint.isBlank()) {
            final var wanted = CertificateAttributesUtil.normalizeHex(thumbprint);
            final var algorithm = wanted.length() == 64 ? "SHA-256" : wanted.length() == 40 ? "SHA-1" : null;
            if (algorithm == null) {
                log.info("currentCertificateThumbprint '{}' has an unexpected length - not used for matching", thumbprint);
            } else {
                if ("SHA-256".equals(algorithm)) {
                    for (CloudflareCertificate c : certificates) {
                        if (wanted.equals(c.getFingerprintSha256())) {
                            return new Selection(List.of(c.getId()),
                                    "SHA-256 thumbprint reported by TLM matched a certificate body already known");
                        }
                    }
                }
                final Map<String, String> bodies = pems == null ? Map.of() : Objects.requireNonNullElse(pems.get(), Map.of());
                if (bodies.isEmpty()) {
                    log.info("currentCertificateThumbprint supplied but no certificate bodies could be fetched from the "
                            + "Cloudflare edge - cannot match by thumbprint");
                } else {
                    for (var e : bodies.entrySet()) {
                        if (!present.contains(e.getKey())) {
                            continue;
                        }
                        try {
                            final var x = CloudflareAutomationPluginHelper.parseFirstCertificate(e.getValue());
                            if (wanted.equals(CertificateAttributesUtil.fingerprintHex(x, algorithm))) {
                                return new Selection(List.of(e.getKey()),
                                        algorithm + " thumbprint reported by TLM (currentCertificateThumbprint)");
                            }
                        } catch (Exception ex) {
                            log.debug("Could not fingerprint '{}': {}", e.getKey(), ex.getMessage());
                        }
                    }
                    log.info("No custom certificate matches currentCertificateThumbprint {}", wanted);
                }
            }
        }

        // 4. endpoint reverse-map
        if (ipAddress != null && !ipAddress.isBlank() && endpointById != null) {
            final List<String> viaEndpoint = new ArrayList<>();
            for (var e : endpointById.entrySet()) {
                if (ipAddress.trim().equalsIgnoreCase(e.getValue()) && present.contains(e.getKey())) {
                    viaEndpoint.add(e.getKey());
                }
            }
            if (!viaEndpoint.isEmpty()) {
                return new Selection(viaEndpoint, "certificate reported on the requested endpoint " + ipAddress);
            }
            log.info("No custom certificate maps to the requested endpoint {}", ipAddress);
        }

        // 5. host coverage (CN / SAN), same key algorithm when known, newest first
        final var names = CertificateAttributesUtil.coveredNames(leaf);
        final var leafKeyType = CertificateAttributesUtil.keyTypeOf(leaf);
        final List<CloudflareCertificate> viaHosts = new ArrayList<>();
        for (CloudflareCertificate c : certificates) {
            boolean covers = false;
            for (String n : names) {
                if (CertificateAttributesUtil.hostsCover(c.getHosts(), n)) {
                    covers = true;
                    break;
                }
            }
            if (!covers) {
                continue;
            }
            if (leafKeyType != null && c.getKeyType() != null && !leafKeyType.equals(c.getKeyType())) {
                log.info("Certificate '{}' covers the hostnames but has a different key algorithm ({} vs {}) - skipped",
                        c.getId(), c.getKeyType(), leafKeyType);
                continue;
            }
            viaHosts.add(c);
        }
        if (!viaHosts.isEmpty()) {
            viaHosts.sort((a, b) -> Long.compare(Objects.requireNonNullElse(b.getExpiresOnEpoch(), 0L),
                    Objects.requireNonNullElse(a.getExpiresOnEpoch(), 0L)));
            final List<String> ids = new ArrayList<>();
            viaHosts.forEach(c -> ids.add(c.getId()));
            return new Selection(ids, "hosts covering the new certificate's CN/SAN " + names
                    + (leafKeyType == null ? "" : " (key algorithm " + leafKeyType.toUpperCase(Locale.ROOT) + ")"));
        }
        return Selection.none("no existing custom certificate matched by alias, thumbprint, endpoint or hosts");
    }

    /** {@code <partition>/<alias>} → {@code alias}; null when blank or the literal "null". */
    public static String stripPartition(String virtualServerName) {
        if (virtualServerName == null || virtualServerName.isBlank()) {
            return null;
        }
        final int slash = virtualServerName.lastIndexOf('/');
        final var name = slash >= 0 ? virtualServerName.substring(slash + 1) : virtualServerName;
        return name.isBlank() || "null".equals(name) ? null : name.trim();
    }
}
