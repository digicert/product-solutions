package com.example.automation.helper;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertTrue;

import java.util.List;

import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;

class CertificateAttributesUtilTest {

    private static final String DN = "CN=www.example.com,OU=Web,O=Example Inc,L=Lehi,ST=Utah,C=US,"
            + "EMAILADDRESS=support@example.com";

    // ── Common name ───────────────────────────────────────────────────────────

    @Test
    @DisplayName("CN is extracted regardless of position and case")
    void commonName() {
        assertEquals("www.example.com", CertificateAttributesUtil.getCommonName(DN));
        assertEquals("a.example.com", CertificateAttributesUtil.getCommonName("O=Example,cn=a.example.com"));
    }

    @Test
    @DisplayName("blank, null or invalid DN yields null CN rather than an exception")
    void commonNameMissing() {
        assertNull(CertificateAttributesUtil.getCommonName(null));
        assertNull(CertificateAttributesUtil.getCommonName(" "));
        assertNull(CertificateAttributesUtil.getCommonName("not a dn"));
        assertNull(CertificateAttributesUtil.getCommonName("O=Example Inc"));
    }

    // ── DNS names ─────────────────────────────────────────────────────────────

    @Test
    @DisplayName("comma-separated SANs are trimmed and empty tokens dropped")
    void dnsNames() {
        assertEquals(List.of("a.example.com", "b.example.com"),
                CertificateAttributesUtil.getDnsNames(" a.example.com, b.example.com ,, "));
        assertTrue(CertificateAttributesUtil.getDnsNames(null).isEmpty());
        assertTrue(CertificateAttributesUtil.getDnsNames("").isEmpty());
    }

    // ── Subject DN fields ─────────────────────────────────────────────────────

    @Test
    @DisplayName("X.500 attributes are mapped onto tmsh gen-csr flag names, CN excluded")
    void subjectDnFields() {
        final var fields = CertificateAttributesUtil.getSubjectDnFields(DN);
        assertEquals("Example Inc", fields.get("organization"));
        assertEquals("Web", fields.get("ou"));
        assertEquals("US", fields.get("country"));
        assertEquals("Utah", fields.get("state"));
        assertEquals("Lehi", fields.get("city"));
        assertEquals("support@example.com", fields.get("email-address"));
        assertEquals(6, fields.size());
    }

    @Test
    @DisplayName("unknown attributes are ignored and a bad DN yields an empty map")
    void subjectDnFieldsTolerant() {
        assertTrue(CertificateAttributesUtil.getSubjectDnFields("CN=x,SERIALNUMBER=1").isEmpty());
        assertTrue(CertificateAttributesUtil.getSubjectDnFields("garbage").isEmpty());
        assertTrue(CertificateAttributesUtil.getSubjectDnFields(null).isEmpty());
    }

    // ── Object name ───────────────────────────────────────────────────────────

    @Test
    @DisplayName("object name is CN_date_flowIdPrefix with non-alphanumerics stripped")
    void objectName() {
        final var name = CertificateAttributesUtil.getObjectName("www.example.com",
                "6855593c-ba92-49e4-8190-54d599979b52", "2026-01-29T23:11:20Z", "/Common/vs_example");
        assertEquals("www.example.com_20260129T231120Z_6855593c", name);
    }

    @Test
    @DisplayName("object name is deterministic: same inputs give the same name for CSR, install and validate")
    void objectNameDeterministic() {
        final var a = CertificateAttributesUtil.getObjectName("cn", "flow-1", "2026-01-01T00:00:00Z", "/Common/vs");
        final var b = CertificateAttributesUtil.getObjectName("cn", "flow-1", "2026-01-01T00:00:00Z", "/Common/vs");
        assertEquals(a, b);
    }

    @Test
    @DisplayName("object name plus parent partition path stays within the F5 255-character limit")
    void objectNameLengthLimit() {
        final var longCn = "a".repeat(300);
        final var parent = "/Common/deep/path";
        final var name = CertificateAttributesUtil.getObjectName(longCn, "flow", "2026", parent + "/vs");
        assertEquals(255 - parent.length(), name.length());
    }

    @Test
    @DisplayName("null CN falls back to 'cert', null flow fields are omitted")
    void objectNameNulls() {
        assertEquals("cert", CertificateAttributesUtil.getObjectName(null, null, null, null));
    }
}
