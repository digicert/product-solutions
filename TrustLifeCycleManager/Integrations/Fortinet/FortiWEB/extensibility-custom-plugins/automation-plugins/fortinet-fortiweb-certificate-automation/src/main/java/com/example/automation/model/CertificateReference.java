package com.example.automation.model;

import lombok.AllArgsConstructor;
import lombok.Data;

/**
 * One place on FortiWeb where a local certificate is referenced. FortiWeb refuses to delete a
 * certificate while any such reference exists, so the plugin must repoint every one of them to the
 * renewed certificate before it can remove the old one.
 */
@Data
@AllArgsConstructor
public class CertificateReference {

    public enum Type {
        /** {@code server-policy/policy} → {@code certificate} field (direct binding). */
        SERVER_POLICY,
        /** {@code system/certificate.sni} → member → {@code local-cert} field. */
        SNI_MEMBER,
        /** {@code system/certificate.multi-local} → {@code rsa-cert} / {@code ecc-cert} / {@code dsa-cert}. */
        MULTI_LOCAL
    }

    private Type type;

    /** Policy name, SNI object name, or multi-local group name (the {@code mkey}). */
    private String objectName;

    /** SNI member id ({@code sub_mkey}) or multi-local field name; null for a server policy. */
    private String subKey;

    /** Name of the local certificate this reference currently points at. */
    private String certificateName;

    @Override
    public String toString() {
        return switch (type) {
            case SERVER_POLICY -> "policy '" + objectName + "'";
            case SNI_MEMBER -> "SNI '" + objectName + "' member '" + subKey + "'";
            case MULTI_LOCAL -> "multi-cert group '" + objectName + "' field '" + subKey + "'";
        };
    }
}
