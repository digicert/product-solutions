package com.digicert.automation.helper;

import org.bouncycastle.cert.jcajce.JcaX509CertificateConverter;
import org.bouncycastle.cert.jcajce.JcaX509v3CertificateBuilder;
import org.bouncycastle.operator.ContentSigner;
import org.bouncycastle.operator.jcajce.JcaContentSignerBuilder;
import org.bouncycastle.util.io.pem.PemObject;
import org.bouncycastle.util.io.pem.PemWriter;
import org.junit.jupiter.api.BeforeAll;
import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;

import javax.security.auth.x500.X500Principal;
import java.io.ByteArrayOutputStream;
import java.io.StringWriter;
import java.math.BigInteger;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.security.KeyPair;
import java.security.KeyPairGenerator;
import java.security.cert.X509Certificate;
import java.util.Base64;
import java.util.Date;
import java.util.zip.ZipEntry;
import java.util.zip.ZipOutputStream;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertThrows;
import static org.junit.jupiter.api.Assertions.assertTrue;

class AutomationPluginHelperTest {

    private static X509Certificate certificate;
    private static String certPem;
    private static String keyPem;

    @BeforeAll
    static void generateSelfSignedCertificate() throws Exception {
        KeyPairGenerator kpg = KeyPairGenerator.getInstance("RSA");
        kpg.initialize(2048);
        KeyPair keyPair = kpg.generateKeyPair();

        X500Principal subject = new X500Principal("CN=f5-xc.digicert-demo.com, O=DigiCert, C=US");
        long now = System.currentTimeMillis();
        JcaX509v3CertificateBuilder builder = new JcaX509v3CertificateBuilder(
                subject, BigInteger.valueOf(0x1234ABCDL), new Date(now - 1000),
                new Date(now + 365L * 24 * 60 * 60 * 1000), subject, keyPair.getPublic());
        ContentSigner signer = new JcaContentSignerBuilder("SHA256withRSA").build(keyPair.getPrivate());
        certificate = new JcaX509CertificateConverter().getCertificate(builder.build(signer));

        certPem = "-----BEGIN CERTIFICATE-----\n"
                + Base64.getMimeEncoder(64, "\n".getBytes(StandardCharsets.UTF_8)).encodeToString(certificate.getEncoded())
                + "\n-----END CERTIFICATE-----";

        StringWriter sw = new StringWriter();
        try (PemWriter pw = new PemWriter(sw)) {
            pw.writeObject(new PemObject("PRIVATE KEY", keyPair.getPrivate().getEncoded()));
        }
        keyPem = sw.toString();
    }

    // ── certificate_url decoding ────────────────────────────────────────────

    @Test
    @DisplayName("decodeF5XCCertificateUrl strips the string:/// prefix and base64-decodes the PEM")
    void decodeCertificateUrl() {
        String encoded = "string:///" + Base64.getEncoder().encodeToString(certPem.getBytes(StandardCharsets.UTF_8));
        assertEquals(certPem, AutomationPluginHelper.decodeF5XCCertificateUrl(encoded));
    }

    @Test
    @DisplayName("decodeF5XCCertificateUrl returns empty string for blank input")
    void decodeCertificateUrl_blank() {
        assertEquals("", AutomationPluginHelper.decodeF5XCCertificateUrl(null));
        assertEquals("", AutomationPluginHelper.decodeF5XCCertificateUrl("  "));
    }

    // ── X.509 utilities ─────────────────────────────────────────────────────

    @Test
    @DisplayName("parseFirstCertificate + getSerialNumberHex returns the upper-case hex serial")
    void serialNumberHex() throws Exception {
        X509Certificate parsed = AutomationPluginHelper.parseFirstCertificate(certPem);
        assertEquals("1234ABCD", AutomationPluginHelper.getSerialNumberHex(parsed));
    }

    @Test
    @DisplayName("getCommonName extracts the subject CN")
    void commonName() {
        assertEquals("f5-xc.digicert-demo.com", AutomationPluginHelper.getCommonName(certificate));
    }

    // ── Issued-certificate extraction (chain only) ──────────────────────────

    @Test
    @DisplayName("extractCertificateChain reads the certificate chain from a ZIP artifact (ignoring any key)")
    void extractChainFromZip() throws Exception {
        Path zip = Files.createTempFile("f5xc-artifact", ".zip");
        try (ZipOutputStream zos = new ZipOutputStream(Files.newOutputStream(zip))) {
            writeEntry(zos, "certificate.cer", certPem);
            writeEntry(zos, "certificate.key", keyPem);
        }

        String chain = AutomationPluginHelper.extractCertificateChain(zip.toString());

        assertTrue(chain.contains("-----BEGIN CERTIFICATE-----"));
        assertTrue(chain.contains("-----END CERTIFICATE-----"));
        assertFalse(chain.contains("PRIVATE KEY"));
        Files.deleteIfExists(zip);
    }

    @Test
    @DisplayName("extractCertificateChain reads a raw PEM certificate artifact")
    void extractChainFromRawPem() throws Exception {
        Path pem = Files.createTempFile("f5xc-cert", ".pem");
        Files.writeString(pem, certPem);

        String chain = AutomationPluginHelper.extractCertificateChain(pem.toString());

        assertTrue(chain.contains("-----BEGIN CERTIFICATE-----"));
        Files.deleteIfExists(pem);
    }

    // ── CSR generation + private-key retention ──────────────────────────────

    @Test
    @DisplayName("generateCsrAndStoreKey returns a CSR and stores a readable private key for the flow")
    void generateCsrStoresKey() throws Exception {
        String flowId = "test-flow-" + System.nanoTime();
        try {
            String csr = AutomationPluginHelper.generateCsrAndStoreKey(
                    flowId, "CN=f5-xc.digicert-demo.com,O=DigiCert,C=US", "RSA", 2048, "sha256",
                    "f5-xc.digicert-demo.com");

            assertTrue(csr.contains("-----BEGIN CERTIFICATE REQUEST-----"));
            String storedKey = AutomationPluginHelper.readStoredPrivateKey(flowId);
            assertTrue(storedKey.contains("PRIVATE KEY"));
        } finally {
            AutomationPluginHelper.deleteFlowDirectory(flowId);
        }
    }

    @Test
    @DisplayName("readStoredPrivateKey throws when generateCsr has not run for the flow")
    void readMissingKeyThrows() {
        assertThrows(IllegalStateException.class,
                () -> AutomationPluginHelper.readStoredPrivateKey("nonexistent-flow-" + System.nanoTime()));
    }

    private static void writeEntry(ZipOutputStream zos, String name, String content) throws Exception {
        zos.putNextEntry(new ZipEntry(name));
        ByteArrayOutputStream baos = new ByteArrayOutputStream();
        baos.write(content.getBytes(StandardCharsets.UTF_8));
        zos.write(baos.toByteArray());
        zos.closeEntry();
    }
}
