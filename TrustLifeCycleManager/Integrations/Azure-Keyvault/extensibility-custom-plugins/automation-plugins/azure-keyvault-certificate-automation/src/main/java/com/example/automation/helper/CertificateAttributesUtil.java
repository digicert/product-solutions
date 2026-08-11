package com.example.automation.helper;

import java.util.ArrayList;
import java.util.List;

import javax.naming.InvalidNameException;
import javax.naming.ldap.LdapName;
import javax.naming.ldap.Rdn;

import lombok.experimental.UtilityClass;

/**
 * Parsing helpers for X.500 subject DNs and a name builder that keeps Azure Key Vault certificate
 * names within the platform rules.
 *
 * <p>Azure Key Vault certificate names may contain only ASCII letters, digits and hyphens
 * ({@code ^[0-9a-zA-Z-]+$}) and are at most 127 characters, so {@link #sanitizeName} maps every
 * other character (dot, underscore, space, …) to a hyphen.
 */
@UtilityClass
public class CertificateAttributesUtil {

    /**
     * @return the CN portion of a subject DN, or {@code null} if none is present.
     */
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

    /**
     * Rebuilds the subject DN into a form Azure Key Vault accepts for {@code policy.x509_props}.
     * Azure validates the subject as an RFC 4514 distinguished name and rejects non-standard
     * attributes such as {@code emailAddress} ("Invalid X.500 distinguished name"), so those are
     * dropped here and surfaced separately via {@link #getEmailAddresses} for the SAN. RDN order and
     * escaping (e.g. {@code O=Acme\, LLC}) are preserved. Falls back to the raw DN if it can't be
     * parsed.
     */
    public static String toAzureSubject(String subjectDn) {
        if (subjectDn == null || subjectDn.isBlank()) {
            return subjectDn;
        }
        try {
            final var rdns = new LdapName(subjectDn).getRdns();
            final List<String> kept = new ArrayList<>();
            // LdapName lists RDNs least-significant-first; iterate in reverse for original order.
            for (int i = rdns.size() - 1; i >= 0; i--) {
                final var rdn = rdns.get(i);
                if (!isEmailType(rdn.getType())) {
                    kept.add(rdn.toString());
                }
            }
            return String.join(",", kept);
        } catch (InvalidNameException e) {
            return subjectDn;
        }
    }

    /**
     * @return the email addresses carried in the subject DN ({@code emailAddress}/{@code E}), which
     *         Azure requires to live in the SAN rather than the subject.
     */
    public static List<String> getEmailAddresses(String subjectDn) {
        final List<String> emails = new ArrayList<>();
        if (subjectDn == null || subjectDn.isBlank()) {
            return emails;
        }
        try {
            for (Rdn rdn : new LdapName(subjectDn).getRdns()) {
                if (isEmailType(rdn.getType())) {
                    emails.add(rdn.getValue().toString());
                }
            }
        } catch (InvalidNameException ignored) {
            // best-effort
        }
        return emails;
    }

    private static boolean isEmailType(String type) {
        return type != null && (type.equalsIgnoreCase("emailAddress")
                || type.equalsIgnoreCase("E")
                || type.equalsIgnoreCase("EMAIL")
                || type.equals("1.2.840.113549.1.9.1"));
    }

    /**
     * @return SubjectAltName DNS names parsed from the comma-separated TLM string, or empty list.
     */
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
     * Builds an Azure-valid certificate name in the form {@code commonName-flowDate-flowIdPrefix},
     * sanitized to {@code [0-9A-Za-z-]} and truncated to {@code maxLength}.
     */
    public static String getObjectName(String commonName, String flowId, String flowStartDate,
                                       int maxLength) {
        final var parts = new ArrayList<String>();
        parts.add(commonName == null || commonName.isBlank() ? "cert" : commonName);
        if (flowStartDate != null && !flowStartDate.isBlank()) {
            parts.add(flowStartDate);
        }
        if (flowId != null && !flowId.isBlank()) {
            parts.add(flowId.length() > 8 ? flowId.substring(0, 8) : flowId);
        }
        return sanitizeName(String.join("-", parts), maxLength);
    }

    /**
     * Sanitizes an arbitrary string into a valid Azure Key Vault certificate name: non-alphanumeric
     * characters become hyphens, runs of hyphens collapse, leading/trailing hyphens are trimmed, the
     * result is truncated to {@code maxLength}, and an empty result falls back to {@code "cert"}.
     */
    public static String sanitizeName(String value, int maxLength) {
        if (value == null || value.isBlank()) {
            return "cert";
        }
        var name = value.replaceAll("[^0-9A-Za-z-]", "-")
                .replaceAll("-{2,}", "-")
                .replaceAll("^-+", "")
                .replaceAll("-+$", "");
        if (name.isEmpty()) {
            name = "cert";
        }
        if (name.length() > maxLength) {
            name = name.substring(0, maxLength).replaceAll("-+$", "");
        }
        return name.isEmpty() ? "cert" : name;
    }
}
