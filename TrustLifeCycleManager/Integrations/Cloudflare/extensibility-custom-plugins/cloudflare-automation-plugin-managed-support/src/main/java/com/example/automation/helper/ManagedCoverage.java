package com.example.automation.helper;

import java.util.ArrayList;
import java.util.Collection;
import java.util.List;
import java.util.Locale;

import lombok.experimental.UtilityClass;

/**
 * Hostname-coverage rules for handing hostnames over from a Cloudflare-managed certificate
 * (Universal SSL / Advanced Certificate Manager pack) to a custom certificate.
 *
 * <p>Cloudflare picks the edge certificate for a hostname by, in order, hostname specificity (an
 * exact name beats a wildcard), zone specificity, certificate type (custom certificates rank
 * above Advanced and Universal) and expiry. Two consequences matter here:
 * <ul>
 *   <li>a managed certificate may only be retired when the custom certificate covers <em>every</em>
 *       hostname of the pack, otherwise those hostnames lose TLS ({@link #uncoveredHosts});</li>
 *   <li>a managed certificate that is kept keeps being served for an exact hostname the custom
 *       certificate covers only through a wildcard ({@link #shadowedHosts}).</li>
 * </ul>
 */
@UtilityClass
public class ManagedCoverage {

    /**
     * Hostnames of the pack the new certificate does not cover. A wildcard pack host is covered only
     * by the same wildcard (an exact name never covers {@code *.example.com}); an exact pack host is
     * covered by the same name or a matching wildcard.
     */
    public static List<String> uncoveredHosts(Collection<String> packHosts, Collection<String> leafNames) {
        final List<String> result = new ArrayList<>();
        if (packHosts == null) {
            return result;
        }
        final var names = lower(leafNames);
        for (String h : packHosts) {
            if (h == null || h.isBlank()) {
                continue;
            }
            final var host = h.trim().toLowerCase(Locale.ROOT);
            final boolean covered = host.startsWith("*.") ? names.contains(host) : CertificateAttributesUtil.hostsCover(names, host);
            if (!covered && !result.contains(host)) {
                result.add(host);
            }
        }
        return result;
    }

    /**
     * Exact hostnames of the pack that the new certificate covers only through a wildcard. Because
     * Cloudflare ranks hostname specificity above certificate type, the pack keeps serving these
     * hostnames as long as it exists.
     */
    public static List<String> shadowedHosts(Collection<String> packHosts, Collection<String> leafNames) {
        final List<String> result = new ArrayList<>();
        if (packHosts == null) {
            return result;
        }
        final var names = lower(leafNames);
        for (String h : packHosts) {
            if (h == null || h.isBlank() || h.trim().startsWith("*")) {
                continue;
            }
            final var host = h.trim().toLowerCase(Locale.ROOT);
            if (!names.contains(host) && CertificateAttributesUtil.hostsCover(names, host) && !result.contains(host)) {
                result.add(host);
            }
        }
        return result;
    }

    /** True when every hostname of the pack is covered by the new certificate. */
    public static boolean fullyCovered(Collection<String> packHosts, Collection<String> leafNames) {
        return uncoveredHosts(packHosts, leafNames).isEmpty();
    }

    private static List<String> lower(Collection<String> values) {
        final List<String> result = new ArrayList<>();
        if (values != null) {
            for (String v : values) {
                if (v != null && !v.isBlank()) {
                    result.add(v.trim().toLowerCase(Locale.ROOT));
                }
            }
        }
        return result;
    }
}
