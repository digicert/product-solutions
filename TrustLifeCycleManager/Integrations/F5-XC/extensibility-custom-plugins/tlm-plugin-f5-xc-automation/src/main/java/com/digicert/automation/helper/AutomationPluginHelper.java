package com.digicert.automation.helper;

import lombok.experimental.UtilityClass;
import lombok.extern.slf4j.Slf4j;
import org.apache.commons.lang3.RandomStringUtils;
import org.bouncycastle.asn1.pkcs.PKCSObjectIdentifiers;
import org.bouncycastle.asn1.x500.X500Name;
import org.bouncycastle.asn1.x509.Extension;
import org.bouncycastle.asn1.x509.ExtensionsGenerator;
import org.bouncycastle.asn1.x509.GeneralName;
import org.bouncycastle.asn1.x509.GeneralNames;
import org.bouncycastle.jce.provider.BouncyCastleProvider;
import org.bouncycastle.operator.ContentSigner;
import org.bouncycastle.operator.jcajce.JcaContentSignerBuilder;
import org.bouncycastle.pkcs.PKCS10CertificationRequest;
import org.bouncycastle.pkcs.PKCS10CertificationRequestBuilder;
import org.bouncycastle.pkcs.jcajce.JcaPKCS10CertificationRequestBuilder;
import org.bouncycastle.util.io.pem.PemObject;
import org.bouncycastle.util.io.pem.PemWriter;

import java.io.ByteArrayInputStream;
import java.io.IOException;
import java.io.StringWriter;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.security.KeyPair;
import java.security.KeyPairGenerator;
import java.security.Security;
import java.security.cert.CertificateFactory;
import java.security.cert.X509Certificate;
import java.util.ArrayList;
import java.util.Base64;
import java.util.Comparator;
import java.util.List;
import java.util.zip.ZipEntry;
import java.util.zip.ZipInputStream;

import javax.naming.ldap.LdapName;
import javax.naming.ldap.Rdn;
import javax.security.auth.x500.X500Principal;

/**
 * Helper utilities for the F5-XC automation plugin.
 * <p>
 * F5-XC uses a <b>decentralized</b> enrollment model (matching the example automation and
 * Kubernetes plugins): the sensor generates the key pair and CSR in {@code generateCsr},
 * <b>retains the private key locally</b> keyed by the TLM {@code flowId}, and TLM issues the
 * certificate from that CSR. {@code installCertificate} then downloads the issued certificate
 * chain, reads back the retained private key, and uploads both as the F5-XC certificate object.
 * The DigiCert artifact therefore supplies only the certificate chain, never the key.
 *
 * @author michael.rudloff
 */
@UtilityClass
@Slf4j
public class AutomationPluginHelper {

    private static final String PLUGIN_NAME = "F5XCAutomationPlugin";
    private static final String PRIVATE_KEY_FILE = "request.key";

    private static final String BEGIN_CERT = "-----BEGIN CERTIFICATE-----";
    private static final String END_CERT = "-----END CERTIFICATE-----";

    static {
        Security.addProvider(new BouncyCastleProvider());
    }

    // ── Temp directory ────────────────────────────────────────────────────────

    public static String createTempDirectory() throws IOException {
        String tempDir = System.getProperty("java.io.tmpdir");
        String randomStr = RandomStringUtils.secure().nextAlphanumeric(8);
        Path pluginDir = Path.of(tempDir, "plugin", randomStr);
        Files.createDirectories(pluginDir);
        return pluginDir.toString();
    }

    public static void deleteTempDirectory(String path) {
        if (path == null) {
            return;
        }
        try {
            Path dirPath = Path.of(path);
            if (Files.exists(dirPath)) {
                try (var pathStream = Files.walk(dirPath)) {
                    pathStream.sorted(Comparator.reverseOrder()).forEach(p -> {
                        try {
                            Files.delete(p);
                        } catch (IOException e) {
                            log.warn("Failed to delete: {}", p, e);
                        }
                    });
                }
                log.info("Successfully deleted temp directory: {}", path);
            }
        } catch (IOException e) {
            log.warn("Failed to delete temp directory: {}", path, e);
        }
    }

    // ── CSR generation + private-key retention (decentralized) ───────────────────

    /**
     * Generates a key pair and PKCS#10 CSR, persists the private key under the flow-scoped
     * directory ({@code <tmpdir>/F5XCAutomationPlugin/<flowId>/request.key}) so a subsequent
     * {@code installCertificate} on the same sensor can upload it, and returns the CSR as PEM.
     *
     * @param flowId             TLM flow id correlating generateCsr with installCertificate
     * @param subjectDn          subject distinguished name (e.g. {@code CN=f5-xc.digicert-demo.com,...})
     * @param keyAlgorithm       key algorithm ({@code RSA} or {@code EC}); defaults to RSA when blank
     * @param keySize            key size in bits (e.g. 2048, 3072, 4096; or EC field size)
     * @param signatureAlgorithm requested signature ({@code sha256} or e.g. {@code SHA256withRSA})
     * @param dnsNames           optional comma-separated SAN DNS names; empty for none
     * @return the generated CSR in PEM form
     */
    public static String generateCsrAndStoreKey(String flowId, String subjectDn, String keyAlgorithm,
                                                int keySize, String signatureAlgorithm, String dnsNames)
            throws Exception {
        String algorithm = (keyAlgorithm == null || keyAlgorithm.isBlank()) ? "RSA" : keyAlgorithm.trim();
        KeyPairGenerator keyPairGenerator = KeyPairGenerator.getInstance(algorithm);
        keyPairGenerator.initialize(keySize);
        KeyPair keyPair = keyPairGenerator.generateKeyPair();

        X500Name subject = new X500Name(subjectDn);
        PKCS10CertificationRequestBuilder requestBuilder =
                new JcaPKCS10CertificationRequestBuilder(subject, keyPair.getPublic());

        List<String> sans = splitDnsNames(dnsNames);
        if (!sans.isEmpty()) {
            GeneralName[] generalNames = sans.stream()
                    .map(name -> new GeneralName(GeneralName.dNSName, name))
                    .toArray(GeneralName[]::new);
            ExtensionsGenerator extensionsGenerator = new ExtensionsGenerator();
            extensionsGenerator.addExtension(Extension.subjectAlternativeName, false, new GeneralNames(generalNames));
            requestBuilder.addAttribute(PKCSObjectIdentifiers.pkcs_9_at_extensionRequest, extensionsGenerator.generate());
        }

        ContentSigner signer = new JcaContentSignerBuilder(resolveSignatureAlgorithm(signatureAlgorithm, algorithm))
                .setProvider("BC").build(keyPair.getPrivate());
        PKCS10CertificationRequest csr = requestBuilder.build(signer);

        String csrPem = toPem("CERTIFICATE REQUEST", csr.getEncoded());
        String keyPem = toPem("PRIVATE KEY", keyPair.getPrivate().getEncoded());

        Path flowDirectory = flowDirectory(flowId);
        Files.createDirectories(flowDirectory);
        Path keyPath = flowDirectory.resolve(PRIVATE_KEY_FILE);
        Files.writeString(keyPath, keyPem);
        log.info("Generated CSR and stored private key for flow '{}' at {}", flowId, keyPath);

        return csrPem;
    }

    /**
     * Reads back the private key persisted by {@link #generateCsrAndStoreKey} for the given flow.
     *
     * @throws IllegalStateException if no key is found (i.e. generateCsr did not run on this sensor)
     */
    public static String readStoredPrivateKey(String flowId) throws IOException {
        Path keyPath = flowDirectory(flowId).resolve(PRIVATE_KEY_FILE);
        if (!Files.exists(keyPath)) {
            throw new IllegalStateException("Private key for flow '" + flowId + "' not found at " + keyPath
                    + ". generateCsr must run on this sensor before installCertificate.");
        }
        return Files.readString(keyPath).trim();
    }

    /** Removes the flow-scoped directory (and the retained private key) once installation completes. */
    public static void deleteFlowDirectory(String flowId) {
        if (flowId == null || flowId.isBlank()) {
            return;
        }
        deleteTempDirectory(flowDirectory(flowId).toString());
    }

    private static Path flowDirectory(String flowId) {
        return Path.of(System.getProperty("java.io.tmpdir"), PLUGIN_NAME, flowId);
    }

    private static List<String> splitDnsNames(String dnsNames) {
        List<String> result = new ArrayList<>();
        if (dnsNames == null || dnsNames.isBlank()) {
            return result;
        }
        for (String token : dnsNames.split(",")) {
            String trimmed = token.trim();
            if (!trimmed.isEmpty()) {
                result.add(trimmed);
            }
        }
        return result;
    }

    private static String resolveSignatureAlgorithm(String signatureAlgorithm, String keyAlgorithm) {
        if (signatureAlgorithm != null && signatureAlgorithm.toLowerCase().contains("with")) {
            return signatureAlgorithm;
        }
        String hash = (signatureAlgorithm == null ? "sha256" : signatureAlgorithm).toLowerCase();
        String digest = switch (hash) {
            case "sha384" -> "SHA384";
            case "sha512" -> "SHA512";
            default -> "SHA256";
        };
        boolean ec = "EC".equalsIgnoreCase(keyAlgorithm);
        return digest + "with" + (ec ? "ECDSA" : "RSA");
    }

    // ── Issued-certificate extraction (chain only) ───────────────────────────────

    /**
     * Extracts the issued certificate chain (end-entity followed by any intermediates) from a
     * downloaded DigiCert artifact. The private key is <b>not</b> sourced here — it is the key
     * the sensor generated in {@code generateCsr} (see {@link #readStoredPrivateKey}).
     * <p>
     * Accepts a ZIP of PEM certificate files ({@code .cer}/{@code .crt}/{@code .pem}) or a raw
     * PEM certificate (chain).
     *
     * @param artifactPath path to the downloaded artifact
     * @return the certificate chain as concatenated PEM
     * @throws IllegalStateException if no certificate can be extracted
     */
    public static String extractCertificateChain(String artifactPath) throws Exception {
        byte[] bytes = Files.readAllBytes(Path.of(artifactPath));
        if (isZip(bytes)) {
            log.info("Issued-certificate artifact detected as ZIP");
            return extractChainFromZip(bytes);
        }
        String content = new String(bytes, StandardCharsets.UTF_8);
        if (content.contains(BEGIN_CERT)) {
            log.info("Issued-certificate artifact detected as raw PEM");
            return extractAllCertBlocks(content);
        }
        throw new IllegalStateException("Downloaded certificate artifact is neither a ZIP nor a PEM certificate");
    }

    private static boolean isZip(byte[] bytes) {
        return bytes.length >= 2 && bytes[0] == 'P' && bytes[1] == 'K';
    }

    private static String extractChainFromZip(byte[] zipBytes) throws Exception {
        String endEntityPem = null;
        List<String> intermediatePems = new ArrayList<>();

        try (ZipInputStream zis = new ZipInputStream(new ByteArrayInputStream(zipBytes))) {
            ZipEntry entry;
            while ((entry = zis.getNextEntry()) != null) {
                String name = entry.getName().toLowerCase();
                if (entry.isDirectory() || name.endsWith(".p7b")) {
                    continue;
                }
                String content = new String(zis.readAllBytes(), StandardCharsets.UTF_8);
                if (!content.contains(BEGIN_CERT)) {
                    continue;
                }
                if (name.contains("_ica") || name.contains("ica.cer") || name.contains("chain") || name.contains("intermediate")) {
                    intermediatePems.add(extractAllCertBlocks(content));
                } else {
                    endEntityPem = extractAllCertBlocks(content);
                }
            }
        }

        // If only one cert file was present and it already held the full chain, endEntity carries it.
        if (endEntityPem == null && !intermediatePems.isEmpty()) {
            endEntityPem = intermediatePems.remove(0);
        }
        if (endEntityPem == null) {
            throw new IllegalStateException("No certificate (.cer/.crt/.pem) found in the downloaded artifact ZIP");
        }

        StringBuilder chain = new StringBuilder(endEntityPem.trim());
        for (String ica : intermediatePems) {
            chain.append("\n").append(ica.trim());
        }
        return chain.toString();
    }

    // ── X.509 / PEM utilities ───────────────────────────────────────────────────

    /** Returns all CERTIFICATE blocks found in {@code content}, concatenated. */
    private static String extractAllCertBlocks(String content) {
        StringBuilder sb = new StringBuilder();
        int idx = 0;
        while ((idx = content.indexOf(BEGIN_CERT, idx)) != -1) {
            int end = content.indexOf(END_CERT, idx);
            if (end == -1) {
                break;
            }
            end += END_CERT.length();
            sb.append(content, idx, end).append("\n");
            idx = end;
        }
        return sb.length() == 0 ? content.trim() : sb.toString().trim();
    }

    /** Parses the first X.509 certificate from a PEM string. */
    public static X509Certificate parseFirstCertificate(String pem) throws Exception {
        CertificateFactory cf = CertificateFactory.getInstance("X.509");
        try (ByteArrayInputStream in = new ByteArrayInputStream(pem.getBytes(StandardCharsets.UTF_8))) {
            return (X509Certificate) cf.generateCertificate(in);
        }
    }

    /** Returns the certificate serial number as an upper-case hexadecimal string. */
    public static String getSerialNumberHex(X509Certificate certificate) {
        return certificate.getSerialNumber().toString(16).toUpperCase();
    }

    /** Extracts the CN (common name) from the certificate subject, or {@code ""} if absent. */
    public static String getCommonName(X509Certificate certificate) {
        try {
            String dn = certificate.getSubjectX500Principal().getName(X500Principal.RFC2253);
            LdapName ldapName = new LdapName(dn);
            for (Rdn rdn : ldapName.getRdns()) {
                if ("CN".equalsIgnoreCase(rdn.getType())) {
                    return rdn.getValue().toString();
                }
            }
        } catch (Exception e) {
            log.warn("Failed to extract CN from certificate subject: {}", e.getMessage());
        }
        return "";
    }

    /**
     * Decodes an F5-XC {@code certificate_url} value of the form
     * {@code string:///<base64-PEM>} into the PEM text.
     */
    public static String decodeF5XCCertificateUrl(String certificateUrl) {
        if (certificateUrl == null || certificateUrl.isBlank()) {
            return "";
        }
        String base64 = certificateUrl.startsWith("string:///")
                ? certificateUrl.substring("string:///".length())
                : certificateUrl;
        return new String(Base64.getDecoder().decode(base64.trim()), StandardCharsets.UTF_8);
    }

    private static String toPem(String type, byte[] der) throws IOException {
        StringWriter writer = new StringWriter();
        try (PemWriter pemWriter = new PemWriter(writer)) {
            pemWriter.writeObject(new PemObject(type, der));
        }
        return writer.toString().trim();
    }
}
