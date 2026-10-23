package com.example.automation.helper;

import java.math.BigInteger;
import java.security.MessageDigest;
import java.security.cert.X509Certificate;
import java.util.ArrayList;
import java.util.Collection;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Locale;
import java.util.Map;

import javax.naming.InvalidNameException;
import javax.naming.ldap.LdapName;
import javax.naming.ldap.Rdn;

import lombok.experimental.UtilityClass;

/**
 * Parsing helpers for X.500 subject DNs, X.509 attributes and Cloudflare host matching.
 */
@UtilityClass
public class CertificateAttributesUtil {

    /** @return the CN portion of a subject DN, or {@code null} if none is present. */
    public static String getCommonName(String subjectDn) {
        return rdnValue(subjectDn, "CN");
    }

    /**
     * @return the first value of the given attribute type ({@code CN}, {@code O}, {@code OU},
     *         {@code L}, {@code ST}, {@code C}) in an RFC 2253 / OpenSSL-style DN, or null.
     */
    public static String rdnValue(String dn, String type) {
        final var map = parseDn(dn);
        return map.get(type.toUpperCase(Locale.ROOT));
    }

    /**
     * Parses a DN into attribute type → first value. Accepts {@code CN=a, O=b} (RFC 2253) and the
     * OpenSSL {@code /CN=a/O=b} form. Unknown attribute types are kept verbatim.
     */
    public static Map<String, String> parseDn(String dn) {
        final Map<String, String> result = new LinkedHashMap<>();
        if (dn == null || dn.isBlank()) {
            return result;
        }
        var text = dn.trim();
        if (text.startsWith("/") && !text.contains(",")) {
            text = text.substring(1).replace("/", ", ");
        }
        try {
            final var ldapName = new LdapName(text);
            // LdapName lists RDNs in reverse (RFC 2253 right-to-left); iterate so the first
            // occurrence in the printed DN wins.
            final var rdns = ldapName.getRdns();
            for (int i = rdns.size() - 1; i >= 0; i--) {
                final Rdn rdn = rdns.get(i);
                final var key = rdn.getType().toUpperCase(Locale.ROOT);
                result.putIfAbsent(key, String.valueOf(rdn.getValue()));
            }
        } catch (InvalidNameException e) {
            // Tolerant fallback: split on commas not inside quotes.
            for (String part : text.split(",(?=(?:[^\"]*\"[^\"]*\")*[^\"]*$)")) {
                final int eq = part.indexOf('=');
                if (eq > 0) {
                    result.putIfAbsent(part.substring(0, eq).trim().toUpperCase(Locale.ROOT),
                            part.substring(eq + 1).trim().replaceAll("^\"|\"$", ""));
                }
            }
        }
        return result;
    }

    /** @return SubjectAltName DNS names parsed from the comma-separated TLM string, or empty list. */
    public static List<String> getDnsNames(String dnsNames) {
        final List<String> result = new ArrayList<>();
        if (dnsNames == null || dnsNames.isBlank()) {
            return result;
        }
        for (String token : dnsNames.split("[,;\\s]+")) {
            final var trimmed = token.trim();
            if (!trimmed.isEmpty() && !result.contains(trimmed)) {
                result.add(trimmed);
            }
        }
        return result;
    }

    /** Upper-case hex serial without a sign nibble, e.g. {@code 0A1B2C…}. */
    public static String serialHex(X509Certificate certificate) {
        return certificate.getSerialNumber().toString(16).toUpperCase(Locale.ROOT);
    }

    /** Compares two serial numbers numerically; false when either side is not parseable as hex. */
    public static boolean sameSerial(String a, String b) {
        final var x = parseSerial(a);
        final var y = parseSerial(b);
        return x != null && y != null && x.equals(y);
    }

    /** Parses a hex serial that may carry spaces, colons or a {@code 0x} prefix; null if invalid. */
    public static BigInteger parseSerial(String serial) {
        if (serial == null) {
            return null;
        }
        var hex = serial.trim().replaceAll("[\\s:]", "");
        if (hex.regionMatches(true, 0, "0x", 0, 2)) {
            hex = hex.substring(2);
        }
        if (hex.isEmpty() || !hex.matches("[0-9A-Fa-f]+")) {
            return null;
        }
        return new BigInteger(hex, 16);
    }

    /** Short key-algorithm label of a certificate's public key: {@code rsa}, {@code ecc}, {@code dsa} or null. */
    public static String keyTypeOf(X509Certificate certificate) {
        final var algorithm = certificate.getPublicKey().getAlgorithm();
        if (algorithm == null) {
            return null;
        }
        return switch (algorithm.toUpperCase(Locale.ROOT)) {
            case "RSA" -> "rsa";
            case "DSA" -> "dsa";
            case "EC", "ECDSA" -> "ecc";
            default -> algorithm.toLowerCase(Locale.ROOT);
        };
    }

    public static Integer keySizeOf(X509Certificate certificate) {
        if (certificate.getPublicKey() instanceof java.security.interfaces.RSAPublicKey rsa) {
            return rsa.getModulus().bitLength();
        }
        if (certificate.getPublicKey() instanceof java.security.interfaces.ECPublicKey ec) {
            return ec.getParams().getCurve().getField().getFieldSize();
        }
        return null;
    }

    /** DNS SubjectAltNames of the certificate, lower-cased, in order. */
    public static List<String> dnsSans(X509Certificate certificate) {
        final List<String> result = new ArrayList<>();
        try {
            final var sans = certificate.getSubjectAlternativeNames();
            if (sans != null) {
                for (List<?> san : sans) {
                    if (san.size() == 2 && Integer.valueOf(2).equals(san.get(0)) && san.get(1) instanceof String s) {
                        final var lower = s.toLowerCase(Locale.ROOT);
                        if (!result.contains(lower)) {
                            result.add(lower);
                        }
                    }
                }
            }
        } catch (Exception ignored) {
            // no usable SAN extension
        }
        return result;
    }

    /** CN plus DNS SANs of the certificate, lower-cased, de-duplicated. */
    public static List<String> coveredNames(X509Certificate certificate) {
        final List<String> names = new ArrayList<>();
        final var cn = getCommonName(certificate.getSubjectX500Principal().getName());
        if (cn != null && !cn.isBlank()) {
            names.add(cn.trim().toLowerCase(Locale.ROOT));
        }
        for (String san : dnsSans(certificate)) {
            if (!names.contains(san)) {
                names.add(san);
            }
        }
        return names;
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

    public static String normalizeHex(String value) {
        return value == null ? "" : value.replaceAll("[^0-9A-Fa-f]", "").toUpperCase(Locale.ROOT);
    }

    /**
     * True when {@code pattern} (a certificate host, possibly {@code *.example.com}) matches
     * {@code host}. A wildcard matches exactly one label, as in RFC 6125.
     */
    public static boolean hostMatches(String pattern, String host) {
        if (pattern == null || host == null) {
            return false;
        }
        final var p = pattern.trim().toLowerCase(Locale.ROOT);
        final var h = host.trim().toLowerCase(Locale.ROOT);
        if (p.equals(h)) {
            return true;
        }
        if (p.startsWith("*.")) {
            final var base = p.substring(2);
            if (!h.endsWith("." + base)) {
                return false;
            }
            final var prefix = h.substring(0, h.length() - base.length() - 1);
            return !prefix.isEmpty() && !prefix.contains(".");
        }
        return false;
    }

    /** True when any of {@code hosts} matches {@code name}. */
    public static boolean hostsCover(Collection<String> hosts, String name) {
        if (hosts == null) {
            return false;
        }
        for (String h : hosts) {
            if (hostMatches(h, name)) {
                return true;
            }
        }
        return false;
    }

    /** Lower-case DNS-label-safe form of a value: {@code [a-z0-9-]}, collapsed and trimmed, non-empty. */
    public static String dnsLabel(String value) {
        if (value == null) {
            return "cert";
        }
        var label = value.toLowerCase(Locale.ROOT).replaceAll("[^a-z0-9-]", "-").replaceAll("-{2,}", "-")
                .replaceAll("^-+", "").replaceAll("-+$", "");
        if (label.isEmpty()) {
            label = "cert";
        }
        return label.length() > 63 ? label.substring(0, 63).replaceAll("-+$", "") : label;
    }
}
