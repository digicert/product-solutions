package com.example.automation.helper;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

import javax.naming.InvalidNameException;
import javax.naming.ldap.LdapName;
import javax.naming.ldap.Rdn;

import lombok.experimental.UtilityClass;

/**
 * Parsing helpers for X.500 subject DNs and a key-name builder that keeps the resulting F5 object
 * name within the 255-character limit imposed by BIG-IP (DA-6929).
 */
@UtilityClass
public class CertificateAttributesUtil {

    private static final int MAX_F5_OBJECT_NAME_LENGTH = 255;

    /** TMSH-supported subject-DN fields (excluding CN/SAN which are passed separately). */
    private static final Map<String, String> DN_TO_TMSH = Map.of(
            "O", "organization",
            "OU", "ou",
            "C", "country",
            "ST", "state",
            "L", "city",
            "EMAILADDRESS", "email-address");

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
     * Maps the parsed subject DN fields (excluding CN) onto the TMSH flag names accepted by
     * {@code tmsh create /sys crypto key … gen-csr}.
     */
    public static Map<String, String> getSubjectDnFields(String subjectDn) {
        final Map<String, String> result = new LinkedHashMap<>();
        if (subjectDn == null || subjectDn.isBlank()) {
            return result;
        }
        try {
            final var ldapName = new LdapName(subjectDn);
            for (Rdn rdn : ldapName.getRdns()) {
                final var tmshField = DN_TO_TMSH.get(rdn.getType().toUpperCase());
                if (tmshField != null) {
                    result.put(tmshField, rdn.getValue().toString());
                }
            }
        } catch (InvalidNameException ignored) {
            // best-effort parsing; missing fields are acceptable
        }
        return result;
    }

    /**
     * Builds an F5 object name in the form {@code commonName_flowDate_flowIdPrefix}, truncated so
     * that {@code parentPath + objectName} stays within the F5 255-character limit.
     */
    public static String getObjectName(String commonName, String flowId, String flowStartDate,
                                       String virtualServerName) {
        final var lastSlash = virtualServerName == null ? -1 : virtualServerName.lastIndexOf('/');
        final var parentPath = lastSlash > 0 ? virtualServerName.substring(0, lastSlash) : "";
        final var maxLength = MAX_F5_OBJECT_NAME_LENGTH - parentPath.length();

        final var safeCn = sanitize(commonName == null ? "cert" : commonName);
        final var safeDate = sanitize(flowStartDate == null ? "" : flowStartDate.replaceAll("[^0-9A-Za-z]", ""));
        final var safeFlow = flowId == null ? "" : flowId.replaceAll("[^0-9A-Za-z]", "").substring(0,
                Math.min(8, flowId.replaceAll("[^0-9A-Za-z]", "").length()));

        var name = safeCn;
        if (!safeDate.isBlank()) name = name + "_" + safeDate;
        if (!safeFlow.isBlank()) name = name + "_" + safeFlow;

        return name.length() > maxLength ? name.substring(0, maxLength) : name;
    }

    private static String sanitize(String value) {
        return value.replaceAll("[^0-9A-Za-z._-]", "");
    }
}
