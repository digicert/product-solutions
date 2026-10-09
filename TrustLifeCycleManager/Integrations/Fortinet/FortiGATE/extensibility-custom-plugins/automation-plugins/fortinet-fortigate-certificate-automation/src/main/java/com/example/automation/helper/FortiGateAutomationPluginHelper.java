package com.example.automation.helper;

import java.io.ByteArrayInputStream;
import java.io.IOException;
import java.io.InputStream;
import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.StandardCopyOption;
import java.nio.file.attribute.PosixFilePermissions;
import java.security.KeyPair;
import java.security.KeyPairGenerator;
import java.security.SecureRandom;
import java.security.cert.CertificateFactory;
import java.security.cert.X509Certificate;
import java.security.spec.ECGenParameterSpec;
import java.time.Duration;
import java.util.ArrayList;
import java.util.Base64;
import java.util.Comparator;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import java.util.regex.Matcher;
import java.util.regex.Pattern;
import java.util.zip.ZipEntry;
import java.util.zip.ZipInputStream;

import javax.net.ssl.SSLContext;
import javax.net.ssl.TrustManager;
import javax.net.ssl.X509TrustManager;

import org.bouncycastle.asn1.pkcs.PKCSObjectIdentifiers;
import org.bouncycastle.asn1.x500.X500Name;
import org.bouncycastle.asn1.x509.Extension;
import org.bouncycastle.asn1.x509.ExtensionsGenerator;
import org.bouncycastle.asn1.x509.GeneralName;
import org.bouncycastle.asn1.x509.GeneralNames;
import org.bouncycastle.operator.ContentSigner;
import org.bouncycastle.operator.jcajce.JcaContentSignerBuilder;
import org.bouncycastle.pkcs.PKCS10CertificationRequest;
import org.bouncycastle.pkcs.jcajce.JcaPKCS10CertificationRequestBuilder;

import com.example.automation.model.FlowRecord;
import com.fasterxml.jackson.databind.ObjectMapper;

import lombok.experimental.UtilityClass;
import lombok.extern.slf4j.Slf4j;

/**
 * Filesystem, crypto and network helpers for the FortiGate automation plugin:
 * <ul>
 *   <li>key-pair + PKCS#10 CSR generation with the private key retained on the sensor, scoped to
 *       the TLM flow ({@code <java.io.tmpdir>/FortiGateAutomationPlugin/<flowId>/});</li>
 *   <li>the {@link FlowRecord} that carries the installed certificate's identity from
 *       {@code installCertificate} to {@code validateCertificate} (each call is a fresh JVM);</li>
 *   <li>downloading the TLM certificate artifact and extracting the end-entity / ICA PEMs.</li>
 * </ul>
 *
 * <p>The key pair is generated with the JDK providers and the CSR is assembled with BouncyCastle's
 * PKCS#10 builder (pure ASN.1; no BC JCE provider registration is required, so the shaded, unsigned
 * BC jar is not a problem).
 */
@UtilityClass
@Slf4j
public class FortiGateAutomationPluginHelper {

    public static final String PLUGIN_NAME = "FortiGateAutomationPlugin";
    private static final String PRIVATE_KEY_FILE = "request.key";
    private static final String CSR_FILE = "request.csr";
    private static final String FLOW_RECORD_FILE = "flow.json";

    private static final ObjectMapper MAPPER = new ObjectMapper();
    private static final Pattern PEM_CERT_PATTERN = Pattern.compile(
            "-----BEGIN CERTIFICATE-----[\\s\\S]+?-----END CERTIFICATE-----");

    // ------------------------------------------------------------------ CSR + key retention

    /**
     * Generates a key pair and a PKCS#10 CSR, stores the private key (PKCS#8 PEM, owner-only
     * permissions) under the flow directory, and returns the CSR as PEM.
     *
     * @param keyAlgorithm       {@code RSA} (default) or {@code EC}/{@code ECDSA}
     * @param keySize            RSA modulus bits (default 2048) or EC field size (256/384/521)
     * @param signatureAlgorithm {@code sha256}/{@code sha384}/{@code sha512} or a full JCA name
     */
    public static String generateCsrAndStoreKey(String flowId, String subjectDn, List<String> dnsNames,
                                                String keyAlgorithm, String keySize,
                                                String signatureAlgorithm) throws Exception {
        final boolean ec = keyAlgorithm != null && keyAlgorithm.trim().toLowerCase().startsWith("ec");
        final KeyPair keyPair = generateKeyPair(ec, keySize);

        final var builder = new JcaPKCS10CertificationRequestBuilder(new X500Name(subjectDn), keyPair.getPublic());
        if (dnsNames != null && !dnsNames.isEmpty()) {
            final GeneralName[] names = dnsNames.stream()
                    .map(n -> new GeneralName(GeneralName.dNSName, n))
                    .toArray(GeneralName[]::new);
            final var extensions = new ExtensionsGenerator();
            extensions.addExtension(Extension.subjectAlternativeName, false, new GeneralNames(names));
            builder.addAttribute(PKCSObjectIdentifiers.pkcs_9_at_extensionRequest, extensions.generate());
        }
        final ContentSigner signer = new JcaContentSignerBuilder(
                resolveSignatureAlgorithm(signatureAlgorithm, ec)).build(keyPair.getPrivate());
        final PKCS10CertificationRequest csr = builder.build(signer);

        final var csrPem = toPem("CERTIFICATE REQUEST", csr.getEncoded());
        final var keyPem = toPem("PRIVATE KEY", keyPair.getPrivate().getEncoded());

        final Path dir = flowDirectory(flowId);
        Files.createDirectories(dir);
        writePrivate(dir.resolve(PRIVATE_KEY_FILE), keyPem);
        Files.writeString(dir.resolve(CSR_FILE), csrPem);
        log.info("Generated {} CSR for flow '{}' (subject [{}], {} SAN(s)); private key retained at {}",
                ec ? "EC" : "RSA", flowId, subjectDn, dnsNames == null ? 0 : dnsNames.size(), dir);
        return csrPem;
    }

    private static KeyPair generateKeyPair(boolean ec, String keySize) throws Exception {
        if (ec) {
            final int bits = parseIntOrDefault(keySize, 256);
            final var curve = switch (bits) {
                case 384 -> "secp384r1";
                case 521 -> "secp521r1";
                default -> "secp256r1";
            };
            final var generator = KeyPairGenerator.getInstance("EC");
            generator.initialize(new ECGenParameterSpec(curve), new SecureRandom());
            return generator.generateKeyPair();
        }
        final var generator = KeyPairGenerator.getInstance("RSA");
        generator.initialize(parseIntOrDefault(keySize, 2048), new SecureRandom());
        return generator.generateKeyPair();
    }

    private static String resolveSignatureAlgorithm(String requested, boolean ec) {
        if (requested != null && requested.toLowerCase().contains("with")) {
            return requested;
        }
        final var hash = requested == null ? "sha256" : requested.toLowerCase().replace("-", "");
        final var digest = switch (hash) {
            case "sha384" -> "SHA384";
            case "sha512" -> "SHA512";
            default -> "SHA256";
        };
        return digest + "with" + (ec ? "ECDSA" : "RSA");
    }

    /**
     * Reads back the private key persisted by {@link #generateCsrAndStoreKey} for the flow.
     *
     * @throws IllegalStateException if no key is found (generateCsr did not run on this sensor)
     */
    public static String readStoredPrivateKey(String flowId) throws IOException {
        final Path keyPath = flowDirectory(flowId).resolve(PRIVATE_KEY_FILE);
        if (!Files.exists(keyPath)) {
            throw new IllegalStateException("Private key for flow '" + flowId + "' not found at " + keyPath
                    + ". generateCsr must run on this sensor before installCertificate.");
        }
        return Files.readString(keyPath).trim();
    }

    /** Removes only the private key once the certificate + key are safely on FortiGate. */
    public static void deleteStoredPrivateKey(String flowId) {
        try {
            Files.deleteIfExists(flowDirectory(flowId).resolve(PRIVATE_KEY_FILE));
            Files.deleteIfExists(flowDirectory(flowId).resolve(CSR_FILE));
        } catch (IOException e) {
            log.warn("Could not delete retained private key for flow '{}': {}", flowId, e.getMessage());
        }
    }

    // ------------------------------------------------------------------ flow record

    public static void writeFlowRecord(String flowId, FlowRecord record) throws IOException {
        final Path dir = flowDirectory(flowId);
        Files.createDirectories(dir);
        writePrivate(dir.resolve(FLOW_RECORD_FILE), MAPPER.writerWithDefaultPrettyPrinter().writeValueAsString(record));
    }

    /** @return the record written by installCertificate for this flow, or null when absent. */
    public static FlowRecord readFlowRecord(String flowId) {
        if (flowId == null || flowId.isBlank()) {
            return null;
        }
        final Path file = flowDirectory(flowId).resolve(FLOW_RECORD_FILE);
        if (!Files.exists(file)) {
            return null;
        }
        try {
            return MAPPER.readValue(Files.readString(file), FlowRecord.class);
        } catch (IOException e) {
            log.warn("Could not read flow record {}: {}", file, e.getMessage());
            return null;
        }
    }

    /** Removes the whole flow directory (key, CSR, record). */
    public static void deleteFlowDirectory(String flowId) {
        if (flowId == null || flowId.isBlank()) {
            return;
        }
        final Path dir = flowDirectory(flowId);
        if (!Files.exists(dir)) {
            return;
        }
        try (var walk = Files.walk(dir)) {
            walk.sorted(Comparator.reverseOrder()).forEach(p -> {
                try {
                    Files.delete(p);
                } catch (IOException e) {
                    log.warn("Failed to delete {}", p);
                }
            });
        } catch (IOException e) {
            log.warn("Failed to delete flow directory {}: {}", dir, e.getMessage());
        }
    }

    public static Path flowDirectory(String flowId) {
        final var safeFlow = flowId == null || flowId.isBlank() ? "unknown-flow"
                : flowId.replaceAll("[^0-9A-Za-z._-]", "_");
        return Path.of(System.getProperty("java.io.tmpdir"), PLUGIN_NAME, safeFlow);
    }

    private static void writePrivate(Path file, String content) throws IOException {
        Files.writeString(file, content);
        try {
            Files.setPosixFilePermissions(file, PosixFilePermissions.fromString("rw-------"));
        } catch (UnsupportedOperationException | IOException ignored) {
            // Windows sensors: ACLs are inherited from the temp directory.
        }
    }

    // ------------------------------------------------------------------ TLM artifact handling

    /** Downloads the TLM certificate artifact (typically a ZIP) into {@code directory}. */
    public static Path downloadFileToDirectory(String fileUrl, String directory) throws IOException {
        final var targetPath = Path.of(directory, "certificate.zip");
        final var client = buildHttpClient();
        final var request = HttpRequest.newBuilder()
                .uri(URI.create(fileUrl))
                .timeout(Duration.ofMinutes(2))
                .GET()
                .build();
        try {
            final HttpResponse<InputStream> response =
                    client.send(request, HttpResponse.BodyHandlers.ofInputStream());
            if (response.statusCode() / 100 != 2) {
                throw new IOException("Failed to download " + fileUrl + ": HTTP " + response.statusCode());
            }
            try (InputStream body = response.body()) {
                Files.copy(body, targetPath, StandardCopyOption.REPLACE_EXISTING);
            }
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
            throw new IOException("Interrupted while downloading " + fileUrl, e);
        }
        return targetPath;
    }

    /**
     * Reads the TLM certificate artifact and returns a map keyed by {@code end_entity.cer} and
     * {@code ica.cer}. Accepts a ZIP of PEM files or a raw PEM (chain); {@code .p7b} entries are ignored.
     */
    public static Map<String, String> extractCertificates(Path artifact) throws IOException {
        final byte[] bytes = Files.readAllBytes(artifact);
        if (bytes.length >= 2 && bytes[0] == 'P' && bytes[1] == 'K') {
            return extractCertificatesFromZip(bytes);
        }
        return splitChainPem(new String(bytes, StandardCharsets.UTF_8));
    }

    private static Map<String, String> extractCertificatesFromZip(byte[] zip) throws IOException {
        final Map<String, String> certs = new HashMap<>();
        try (ZipInputStream zis = new ZipInputStream(new ByteArrayInputStream(zip))) {
            ZipEntry entry;
            while ((entry = zis.getNextEntry()) != null) {
                final var name = entry.getName().toLowerCase();
                if (entry.isDirectory() || name.endsWith(".p7b")) {
                    continue;
                }
                final var content = new String(zis.readAllBytes(), StandardCharsets.UTF_8);
                if (!content.contains("-----BEGIN CERTIFICATE-----")) {
                    continue;
                }
                if (name.contains("_ica") || name.endsWith("ica.cer") || name.contains("intermediate")
                        || name.contains("chain")) {
                    certs.put("ica.cer", content);
                } else {
                    certs.put("end_entity.cer", content);
                }
            }
        }
        // A single file that already holds the chain: first block is the leaf, the rest the ICA.
        if (!certs.containsKey("end_entity.cer") && certs.containsKey("ica.cer")) {
            return splitChainPem(certs.get("ica.cer"));
        }
        if (certs.containsKey("end_entity.cer") && !certs.containsKey("ica.cer")) {
            final var split = splitChainPem(certs.get("end_entity.cer"));
            if (split.containsKey("ica.cer")) {
                return split;
            }
        }
        return certs;
    }

    /**
     * Splits a concatenated PEM chain: the first block becomes {@code end_entity.cer}; every
     * following block is appended to {@code ica.cer}.
     */
    public static Map<String, String> splitChainPem(String chainPem) {
        final Map<String, String> result = new HashMap<>();
        if (chainPem == null || chainPem.isBlank()) {
            return result;
        }
        final Matcher m = PEM_CERT_PATTERN.matcher(chainPem);
        final var ica = new StringBuilder();
        int index = 0;
        while (m.find()) {
            final var pem = m.group() + "\n";
            if (index == 0) {
                result.put("end_entity.cer", pem);
            } else {
                ica.append(pem);
            }
            index++;
        }
        if (ica.length() > 0) {
            result.put("ica.cer", ica.toString());
        }
        return result;
    }

    // ------------------------------------------------------------------ X.509 / PEM

    /** Parses the first X.509 certificate from a PEM string. */
    public static X509Certificate parseFirstCertificate(String pem) throws Exception {
        final var factory = CertificateFactory.getInstance("X.509");
        try (var in = new ByteArrayInputStream(pem.getBytes(StandardCharsets.UTF_8))) {
            return (X509Certificate) factory.generateCertificate(in);
        }
    }

    /** Wraps DER bytes as a 64-column PEM block of the given type. */
    public static String toPem(String type, byte[] der) {
        final var base64 = Base64.getEncoder().encodeToString(der);
        final var body = new StringBuilder();
        for (int i = 0; i < base64.length(); i += 64) {
            body.append(base64, i, Math.min(i + 64, base64.length())).append('\n');
        }
        return "-----BEGIN " + type + "-----\n" + body + "-----END " + type + "-----\n";
    }

    /** Ensures a PEM body ends with exactly one newline (FortiOS's parser is picky about trailing bytes). */
    public static String normalizePem(String pem) {
        return pem == null ? null : pem.strip() + "\n";
    }

    public static int parseIntOrDefault(String value, int fallback) {
        try {
            return value == null || value.isBlank() ? fallback : Integer.parseInt(value.trim());
        } catch (NumberFormatException e) {
            return fallback;
        }
    }

    /** Returns all PEM certificate blocks in order (used to build the upload file). */
    public static List<String> allCertBlocks(String pem) {
        final List<String> blocks = new ArrayList<>();
        if (pem == null) {
            return blocks;
        }
        final Matcher m = PEM_CERT_PATTERN.matcher(pem);
        while (m.find()) {
            blocks.add(m.group());
        }
        return blocks;
    }

    private static HttpClient buildHttpClient() {
        try {
            final var trustAll = new TrustManager[] { new X509TrustManager() {
                @Override public void checkClientTrusted(X509Certificate[] c, String a) { }
                @Override public void checkServerTrusted(X509Certificate[] c, String a) { }
                @Override public X509Certificate[] getAcceptedIssuers() { return new X509Certificate[0]; }
            } };
            final var ctx = SSLContext.getInstance("TLS");
            ctx.init(null, trustAll, new SecureRandom());
            return HttpClient.newBuilder()
                    .connectTimeout(Duration.ofSeconds(30))
                    .sslContext(ctx)
                    .version(HttpClient.Version.HTTP_1_1)
                    .build();
        } catch (Exception e) {
            throw new IllegalStateException("Failed to build trust-all HttpClient", e);
        }
    }
}
