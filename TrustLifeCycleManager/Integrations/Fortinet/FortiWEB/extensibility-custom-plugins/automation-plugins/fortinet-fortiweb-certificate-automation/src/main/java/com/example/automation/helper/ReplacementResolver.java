package com.example.automation.helper;

import java.security.MessageDigest;
import java.security.cert.X509Certificate;
import java.util.ArrayList;
import java.util.Collection;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Set;

import com.example.automation.model.FortiWebCertificate;

import lombok.extern.slf4j.Slf4j;

/**
 * Decides which FortiWeb certificate(s) an install replaces.
 *
 * <p>TLM identifies the certificate being renewed in several, not always consistent, ways: the
 * asset alias round-tripped in {@code virtualServerName}, the SHA-256 thumbprint of the certificate
 * it last saw ({@code currentCertificateThumbprint}), and the endpoint ({@code ipAddress}) the
 * request is for. The alias can be <em>stale</em> — TLM keeps the alias it discovered first, while
 * every FortiWeb renewal produces a new object name — so trusting it alone leaves the previous
 * certificate bound and undeleted. This resolver therefore tries, in order, and only accepts a
 * certificate that actually exists on the appliance:
 * <ol>
 *   <li>an explicit {@code certificateName} override,</li>
 *   <li>the round-tripped alias,</li>
 *   <li>the thumbprint, matched against the certificate bodies read from the CLI over SSH,</li>
 *   <li>the endpoint: the certificate whose stable discovery endpoint equals the request's
 *       {@code ipAddress},</li>
 *   <li>subject match: certificates whose CN equals the new leaf's CN or one of its SAN DNS names,
 *       with the same key algorithm (an RSA renewal never selects an ECC certificate).</li>
 * </ol>
 * The chosen strategy is reported so the install log explains the decision.
 */
@Slf4j
public final class ReplacementResolver {

    private ReplacementResolver() {
    }

    /** Names to rotate out plus a human-readable description of how they were chosen. */
    public record Selection(List<String> names, String strategy) {
        public static Selection none(String reason) {
            return new Selection(List.of(), reason);
        }
        public boolean isEmpty() {
            return names.isEmpty();
        }
    }

    /**
     * @param certificates      current FortiWeb list (metadata)
     * @param cliPems           certificate name → PEM read over SSH (may be empty)
     * @param endpointByName    certificate name → stable discovery endpoint host (as discovery reports it)
     * @param explicit          {@code certificateName} from the request, may be null
     * @param virtualServerName {@code <partition>/<alias>} from the request, may be null
     * @param thumbprint        {@code currentCertificateThumbprint} from the request, may be null
     * @param ipAddress         endpoint host from the request, may be null
     * @param leaf              the newly issued certificate
     * @param newName           the FortiWeb name the new certificate will be imported under (excluded)
     */
    public static Selection resolve(List<FortiWebCertificate> certificates, Map<String, String> cliPems,
                                    Map<String, String> endpointByName, String explicit, String virtualServerName,
                                    String thumbprint, String ipAddress, X509Certificate leaf, String newName) {
        final Set<String> present = new LinkedHashSet<>();
        certificates.forEach(c -> present.add(c.getName()));

        // 1. explicit override
        if (explicit != null && !explicit.isBlank()) {
            if (present.contains(explicit.trim())) {
                return new Selection(List.of(explicit.trim()), "explicit certificateName");
            }
            log.warn("certificateName '{}' is not present on FortiWeb - ignoring the override", explicit);
        }

        // 2. round-tripped alias
        final var alias = stripPartition(virtualServerName);
        if (alias != null) {
            if (present.contains(alias)) {
                return new Selection(List.of(alias), "asset alias round-tripped by TLM (virtualServerName)");
            }
            log.warn("TLM round-tripped alias '{}' but no such certificate exists on FortiWeb (stale alias after an "
                    + "earlier rotation?) - falling back to thumbprint / endpoint / subject matching", alias);
        }

        // 3. thumbprint against CLI bodies
        if (thumbprint != null && !thumbprint.isBlank()) {
            final var wanted = normalizeHex(thumbprint);
            final var algorithm = wanted.length() == 64 ? "SHA-256" : wanted.length() == 40 ? "SHA-1" : null;
            if (algorithm == null) {
                log.info("currentCertificateThumbprint '{}' has an unexpected length - not used for matching", thumbprint);
            } else if (cliPems == null || cliPems.isEmpty()) {
                log.info("currentCertificateThumbprint supplied but no certificate bodies are available (SSH off?) - cannot match by thumbprint");
            } else {
                for (var e : cliPems.entrySet()) {
                    if (!present.contains(e.getKey()) || e.getKey().equals(newName)) {
                        continue;
                    }
                    try {
                        final var x = FortiWebAutomationPluginHelper.parseFirstCertificate(e.getValue());
                        if (wanted.equals(fingerprintHex(x, algorithm))) {
                            return new Selection(List.of(e.getKey()),
                                    algorithm + " thumbprint reported by TLM (currentCertificateThumbprint)");
                        }
                    } catch (Exception ex) {
                        log.debug("Could not fingerprint '{}': {}", e.getKey(), ex.getMessage());
                    }
                }
                log.info("No FortiWeb certificate matches currentCertificateThumbprint {}", wanted);
            }
        }

        // 4. endpoint reverse-map
        if (ipAddress != null && !ipAddress.isBlank() && endpointByName != null) {
            final List<String> viaEndpoint = new ArrayList<>();
            for (var e : endpointByName.entrySet()) {
                if (ipAddress.trim().equalsIgnoreCase(e.getValue()) && present.contains(e.getKey())
                        && !e.getKey().equals(newName)) {
                    viaEndpoint.add(e.getKey());
                }
            }
            if (!viaEndpoint.isEmpty()) {
                return new Selection(viaEndpoint, "certificate(s) reported on the requested endpoint " + ipAddress);
            }
            log.info("No FortiWeb certificate maps to the requested endpoint {}", ipAddress);
        }

        // 5. subject match (CN or SAN) with the same key algorithm
        final Set<String> subjectNames = new LinkedHashSet<>();
        final var leafCn = CertificateAttributesUtil.getCommonName(leaf.getSubjectX500Principal().getName());
        if (leafCn != null) {
            subjectNames.add(leafCn.toLowerCase(Locale.ROOT));
        }
        subjectNames.addAll(dnsSans(leaf));
        final Integer leafPkeyType = pkeyTypeOf(leaf);
        final List<String> viaSubject = new ArrayList<>();
        for (FortiWebCertificate c : certificates) {
            if (c.getName().equals(newName) || c.getCommonName() == null) {
                continue;
            }
            if (!subjectNames.contains(c.getCommonName().toLowerCase(Locale.ROOT))) {
                continue;
            }
            if (leafPkeyType != null && c.getPkeyType() != null && !leafPkeyType.equals(c.getPkeyType())) {
                log.info("Certificate '{}' matches by subject but has a different key algorithm (pkey_type {} vs {}) - skipped",
                        c.getName(), c.getPkeyType(), leafPkeyType);
                continue;
            }
            viaSubject.add(c.getName());
        }
        if (!viaSubject.isEmpty()) {
            return new Selection(viaSubject, "subject CN equal to the new certificate's CN/SAN " + subjectNames
                    + " with the same key algorithm");
        }
        return Selection.none("no existing certificate matched by alias, thumbprint, endpoint or subject");
    }

    /** {@code <partition>/<name>} → {@code name}; null when blank or the literal "null". */
    public static String stripPartition(String virtualServerName) {
        if (virtualServerName == null || virtualServerName.isBlank()) {
            return null;
        }
        final int slash = virtualServerName.lastIndexOf('/');
        final var name = slash >= 0 ? virtualServerName.substring(slash + 1) : virtualServerName;
        return name.isBlank() || "null".equals(name) ? null : name.trim();
    }

    /** Upper-case hex digest of the certificate's DER encoding. */
    public static String fingerprintHex(X509Certificate certificate, String algorithm) throws Exception {
        final var digest = MessageDigest.getInstance(algorithm).digest(certificate.getEncoded());
        final var sb = new StringBuilder(digest.length * 2);
        for (byte b : digest) {
            sb.append(String.format("%02X", b));
        }
        return sb.toString();
    }

    static String normalizeHex(String value) {
        return value.replaceAll("[^0-9A-Fa-f]", "").toUpperCase(Locale.ROOT);
    }

    /** DNS SubjectAltNames of the certificate, lower-cased. */
    static Collection<String> dnsSans(X509Certificate certificate) {
        final List<String> result = new ArrayList<>();
        try {
            final var sans = certificate.getSubjectAlternativeNames();
            if (sans != null) {
                for (List<?> san : sans) {
                    if (san.size() == 2 && Integer.valueOf(2).equals(san.get(0)) && san.get(1) instanceof String s) {
                        result.add(s.toLowerCase(Locale.ROOT));
                    }
                }
            }
        } catch (Exception ignored) {
            // no usable SAN extension
        }
        return result;
    }

    /** FortiWeb pkey_type code for the leaf's key algorithm (RSA = 1, EC = 3 as observed on 8.0.5), or null. */
    static Integer pkeyTypeOf(X509Certificate certificate) {
        final var algorithm = certificate.getPublicKey().getAlgorithm();
        if (algorithm == null) {
            return null;
        }
        return switch (algorithm.toUpperCase(Locale.ROOT)) {
            case "RSA" -> 1;
            case "DSA" -> 2;
            case "EC", "ECDSA" -> 3;
            default -> null;
        };
    }
}
