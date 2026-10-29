package com.example.automation.helper;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertTrue;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.zip.ZipEntry;
import java.util.zip.ZipOutputStream;

import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;
import org.junit.jupiter.api.io.TempDir;

class F5AutomationPluginHelperTest {

    private static final String EE = "-----BEGIN CERTIFICATE-----\nMIIBee\n-----END CERTIFICATE-----";
    private static final String ICA = "-----BEGIN CERTIFICATE-----\nMIIBica\n-----END CERTIFICATE-----";
    private static final String ROOT = "-----BEGIN CERTIFICATE-----\nMIIBroot\n-----END CERTIFICATE-----";

    @TempDir
    Path tempDir;

    static Path writeZip(Path dir, Map<String, String> entries) throws IOException {
        final var zip = dir.resolve("certificate.zip");
        try (ZipOutputStream zos = new ZipOutputStream(Files.newOutputStream(zip))) {
            for (var entry : entries.entrySet()) {
                zos.putNextEntry(new ZipEntry(entry.getKey()));
                zos.write(entry.getValue().getBytes(StandardCharsets.UTF_8));
                zos.closeEntry();
            }
        }
        return zip;
    }

    // ── splitChainPem ─────────────────────────────────────────────────────────

    @Test
    @DisplayName("inline chain: first PEM is the end-entity, second is the ICA, further PEMs ignored")
    void splitChain() {
        final var certs = F5AutomationPluginHelper.splitChainPem(EE + "\n" + ICA + "\n" + ROOT);
        assertEquals(EE + "\n", certs.get("end_entity.cer"));
        assertEquals(ICA + "\n", certs.get("ica.cer"));
        assertEquals(2, certs.size());
    }

    @Test
    @DisplayName("inline chain with only the end-entity yields no ICA entry")
    void splitChainNoIca() {
        final var certs = F5AutomationPluginHelper.splitChainPem(EE);
        assertTrue(certs.containsKey("end_entity.cer"));
        assertFalse(certs.containsKey("ica.cer"));
    }

    @Test
    @DisplayName("blank chain yields an empty map")
    void splitChainBlank() {
        assertTrue(F5AutomationPluginHelper.splitChainPem(null).isEmpty());
        assertTrue(F5AutomationPluginHelper.splitChainPem("  ").isEmpty());
    }

    // ── extractCertificatesFromZip ────────────────────────────────────────────

    @Test
    @DisplayName("TLM zip: *_ica.cer is the ICA, the other .cer is the end-entity, .p7b is ignored")
    void extractFromZip() throws IOException {
        final var entries = new LinkedHashMap<String, String>();
        entries.put("www.example.com.p7b", "pkcs7-bytes");
        entries.put("www.example.com.cer", EE);
        entries.put("www.example.com_ica.cer", ICA);
        final var zip = writeZip(tempDir, entries);

        final var certs = F5AutomationPluginHelper.extractCertificatesFromZip(zip);

        assertEquals(EE, certs.get("end_entity.cer"));
        assertEquals(ICA, certs.get("ica.cer"));
        assertEquals(2, certs.size());
    }

    @Test
    @DisplayName("ICA entry can come before the end-entity entry")
    void extractFromZipAnyOrder() throws IOException {
        final var entries = new LinkedHashMap<String, String>();
        entries.put("www.example.com_ica.cer", ICA);
        entries.put("www.example.com.cer", EE);
        final var certs = F5AutomationPluginHelper.extractCertificatesFromZip(writeZip(tempDir, entries));
        assertEquals(EE, certs.get("end_entity.cer"));
        assertEquals(ICA, certs.get("ica.cer"));
    }

    @Test
    @DisplayName("zip without a .cer yields no end-entity")
    void extractFromZipEmpty() throws IOException {
        final var zip = writeZip(tempDir, Map.of("readme.txt", "nothing"));
        assertTrue(F5AutomationPluginHelper.extractCertificatesFromZip(zip).isEmpty());
        assertNull(F5AutomationPluginHelper.extractCertificateFromZip(zip.toString()));
    }
}
