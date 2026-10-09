package com.example.automation.model;

import java.util.regex.Matcher;
import java.util.regex.Pattern;

import lombok.Data;

/**
 * One entry of the FortiWeb local-certificate list ({@code GET /api/v2.0/system/certificate.local}).
 * Field names follow the JSON FortiWeb returns, e.g.
 * <pre>
 * { "_id": "cer", "name": "cer", "q_ref": 0, "cert_type": "local", "pkey_type": 1,
 *   "can_delete": true, "status": "OK",
 *   "issuer": "C = us, ..., CN = tlsguru.com, ...", "subject": "C = us, ..., CN = tlsguru.com, ...",
 *   "validFrom": "2026-09-21 10:24:42  GMT", "validTo": "2027-09-21 10:24:42  GMT",
 *   "serialNumber": "00 " }
 * </pre>
 */
@Data
public class FortiWebCertificate {

    private static final Pattern CN_PATTERN = Pattern.compile("CN\\s*=\\s*([^,/]+)", Pattern.CASE_INSENSITIVE);

    /** FortiWeb object name (the {@code mkey}); this is what policies / SNI members reference. */
    private String name;

    /** Reference count reported by FortiWeb; {@code 0} means no object uses this certificate. */
    private int refCount;

    /** FortiWeb key-algorithm code ({@code pkey_type}); observed RSA = 1, ECDSA = 3. Null when absent. */
    private Integer pkeyType;

    /** FortiWeb's own "may be deleted" flag; false while any object still references the cert. */
    private Boolean canDelete;

    /** FortiWeb status string, e.g. {@code OK}. */
    private String status;

    private String issuer;
    private String subject;
    private String validFrom;
    private String validTo;

    /** Serial as FortiWeb prints it (hex, may contain spaces/colons, e.g. {@code "00 "}). */
    private String serialNumber;

    /**
     * PEM of the certificate when it could be obtained (see
     * {@code FortiWebAdapter#tryFetchCertificatePem}); null otherwise — FortiWeb does not return
     * the certificate body in the list.
     */
    private String certificatePem;

    /** @return the CN portion of {@link #subject}, or null. */
    public String getCommonName() {
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

    /** @return true when FortiWeb reports the certificate as unreferenced and deletable. */
    public boolean isUnreferenced() {
        if (canDelete != null) {
            return canDelete;
        }
        return refCount == 0;
    }
}
