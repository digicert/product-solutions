package com.example.automation.helper;

import java.math.BigInteger;
import java.security.cert.X509Certificate;
import java.util.ArrayList;
import java.util.List;

import javax.naming.InvalidNameException;
import javax.naming.ldap.LdapName;
import javax.naming.ldap.Rdn;

import lombok.experimental.UtilityClass;

/**
 * Parsing helpers for X.500 subject DNs plus the naming rules for FortiWeb local certificates.
 *
 * <p>FortiWeb derives a local certificate's object name from the uploaded file name and only
 * tolerates letters, digits and underscores in it; object names are also short (the CLI caps
 * {@code edit <name>} at {@value #MAX_NAME_LENGTH} characters). {@link #sanitizeName} enforces both.
 */
@UtilityClass
public class CertificateAttributesUtil {

    /** Maximum length of a FortiWeb object name. */
    public static final int MAX_NAME_LENGTH = 35;

    /** @return the CN portion of a subject DN, or {@code null} if none is present. */
    public static String getCommonName(String subjectDn) {
        if (subjectDn == null || subjectDn.isBlank()) {
            return null;
        }
        try {
            final var ldapName = new LdapName(subjectDn);
            for (Rdn rdn : ldapName.getRdns()) {
                if ("CN".equalsIgnoreCase(rdn.getType())) {
                    return rdn.getValue().toString();
                }
            }
        } catch (InvalidNameException e) {
            return null;
        }
        return null;
    }

    /** @return SubjectAltName DNS names parsed from the comma-separated TLM string, or empty list. */
    public static List<String> getDnsNames(String dnsNames) {
        final List<String> result = new ArrayList<>();
        if (dnsNames == null || dnsNames.isBlank()) {
            return result;
        }
        for (String token : dnsNames.split(",")) {
            final var trimmed = token.trim();
            if (!trimmed.isEmpty()) {
                result.add(trimmed);
            }
        }
        return result;
    }

    /**
     * Builds the unique FortiWeb object name the renewed certificate is imported under:
     * {@code <sanitised CN>_<last 12 hex digits of the serial>} — the same convention as the proven
     * shell automation. FortiWeb cannot overwrite an existing certificate (duplicate-name error), so
     * every renewal needs a fresh, unique name; the serial suffix guarantees that while the CN
     * prefix keeps the name recognisable. The CN part is truncated so the whole name fits FortiWeb's
     * length limit.
     */
    public static String buildUniqueName(String commonName, String serialHex, String fallbackBase) {
        var base = commonName == null || commonName.isBlank() ? fallbackBase : commonName;
        base = sanitizeName(base, MAX_NAME_LENGTH);
        var suffix = serialHex == null ? "" : serialHex.toLowerCase().replaceAll("[^0-9a-f]", "");
        if (suffix.isEmpty()) {
            suffix = Long.toHexString(System.currentTimeMillis());
        }
        if (suffix.length() > 12) {
            suffix = suffix.substring(suffix.length() - 12);
        }
        final int maxBase = MAX_NAME_LENGTH - 1 - suffix.length();
        if (base.length() > maxBase) {
            base = base.substring(0, maxBase).replaceAll("_+$", "");
        }
        return base + "_" + suffix;
    }

    /**
     * Sanitizes an arbitrary string into a valid FortiWeb object name: every character outside
     * {@code [A-Za-z0-9_]} becomes an underscore, runs of underscores collapse, leading/trailing
     * underscores are trimmed, the result is truncated to {@code maxLength}, and an empty result
     * falls back to {@code "cert"}.
     */
    public static String sanitizeName(String value, int maxLength) {
        if (value == null || value.isBlank()) {
            return "cert";
        }
        var name = value.replaceAll("[^0-9A-Za-z_]", "_")
                .replaceAll("_{2,}", "_")
                .replaceAll("^_+", "")
                .replaceAll("_+$", "");
        if (name.isEmpty()) {
            name = "cert";
        }
        if (name.length() > maxLength) {
            name = name.substring(0, maxLength).replaceAll("_+$", "");
        }
        return name.isEmpty() ? "cert" : name;
    }

    /** Upper-case hex serial without a sign nibble, e.g. {@code 0A1B2C…}. */
    public static String serialHex(X509Certificate certificate) {
        return certificate.getSerialNumber().toString(16).toUpperCase();
    }

    /**
     * Compares two serial numbers numerically so hex case, colons/spaces and leading zeros
     * ({@code "00 "} vs {@code "0"}) never cause a false mismatch. Returns false when either side
     * is not parseable as hex.
     */
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
}
