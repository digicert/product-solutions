package com.example.automation.helper;

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
import java.security.SecureRandom;
import java.security.cert.X509Certificate;
import java.time.Duration;
import java.util.HashMap;
import java.util.Map;
import java.util.regex.Matcher;
import java.util.regex.Pattern;
import java.util.zip.ZipEntry;
import java.util.zip.ZipInputStream;

import javax.net.ssl.SSLContext;
import javax.net.ssl.TrustManager;
import javax.net.ssl.X509TrustManager;

import lombok.experimental.UtilityClass;

/**
 * Filesystem and network helpers for the Azure Key Vault automation plugin: downloading the cert
 * artifact TLM produces, extracting the end-entity and ICA certs from the TLM ZIP, and splitting an
 * inline PEM chain. These are transport-agnostic and reused across the lifecycle operations.
 */
@UtilityClass
public class AzureKeyvaultAutomationPluginHelper {

    private static final Pattern PEM_CERT_PATTERN = Pattern.compile(
            "-----BEGIN CERTIFICATE-----[\\s\\S]+?-----END CERTIFICATE-----");

    /**
     * Downloads the TLM certificate artifact referenced by {@code fileUrl} (typically a ZIP)
     * into {@code directory} and returns the local path.
     */
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
     * Reads the TLM certificate ZIP and returns a map keyed by {@code end_entity.cer} and
     * {@code ica.cer}. {@code .p7b} entries are ignored.
     */
    public static Map<String, String> extractCertificatesFromZip(Path zipFilePath) throws IOException {
        final Map<String, String> certs = new HashMap<>();
        try (ZipInputStream zis = new ZipInputStream(Files.newInputStream(zipFilePath))) {
            ZipEntry entry;
            while ((entry = zis.getNextEntry()) != null) {
                final var name = entry.getName();
                if (name.endsWith(".p7b")) {
                    continue;
                }
                if (name.endsWith("_ica.cer") || name.endsWith("ica.cer")) {
                    certs.put("ica.cer", readEntry(zis));
                } else if (name.endsWith(".cer")) {
                    certs.put("end_entity.cer", readEntry(zis));
                }
            }
        }
        return certs;
    }

    /**
     * Extracts the end-entity (and, if present, ICA) PEM from a concatenated cert-chain string.
     * Useful when the SDK passes the chain inline rather than as a downloadable artifact.
     */
    public static Map<String, String> splitChainPem(String chainPem) {
        final Map<String, String> result = new HashMap<>();
        if (chainPem == null || chainPem.isBlank()) {
            return result;
        }
        final Matcher m = PEM_CERT_PATTERN.matcher(chainPem);
        int index = 0;
        while (m.find()) {
            final var pem = m.group() + "\n";
            if (index == 0) {
                result.put("end_entity.cer", pem);
            } else if (!result.containsKey("ica.cer")) {
                result.put("ica.cer", pem);
            }
            index++;
        }
        return result;
    }

    private static String readEntry(ZipInputStream zis) throws IOException {
        // Read only the current entry's bytes — ZipInputStream.read returns -1 at end-of-entry,
        // not end-of-stream. Do NOT wrap in a Reader inside try-with-resources: closing the Reader
        // would close the underlying ZipInputStream and break the next getNextEntry() call.
        final var buffer = new java.io.ByteArrayOutputStream();
        final var buf = new byte[8192];
        int n;
        while ((n = zis.read(buf)) > 0) {
            buffer.write(buf, 0, n);
        }
        return buffer.toString(StandardCharsets.UTF_8);
    }

    private static HttpClient buildHttpClient() {
        try {
            final var trustAll = new TrustManager[] { new X509TrustManager() {
                @Override public void checkClientTrusted(X509Certificate[] c, String a) {}
                @Override public void checkServerTrusted(X509Certificate[] c, String a) {}
                @Override public X509Certificate[] getAcceptedIssuers() { return new X509Certificate[0]; }
            }};
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
