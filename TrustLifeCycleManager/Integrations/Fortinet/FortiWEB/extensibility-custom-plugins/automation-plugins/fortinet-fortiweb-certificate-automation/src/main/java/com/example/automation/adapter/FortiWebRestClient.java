package com.example.automation.adapter;

import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.net.ProxySelector;
import java.net.URI;
import java.net.URLEncoder;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.nio.charset.StandardCharsets;
import java.security.SecureRandom;
import java.security.cert.X509Certificate;
import java.time.Duration;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.UUID;

import javax.net.ssl.SSLContext;
import javax.net.ssl.TrustManager;
import javax.net.ssl.X509TrustManager;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;

import lombok.Getter;
import lombok.extern.slf4j.Slf4j;

/**
 * Thin HTTP client for the FortiWeb REST API ({@code /api/v2.0/…}) built on the JDK
 * {@link HttpClient}.
 *
 * <ul>
 *   <li>Every request carries {@code Authorization: <token>} — the raw base64 credential token,
 *       no {@code Bearer} prefix (this is how FortiWeb expects it).</li>
 *   <li>TLS is trust-all with hostname verification disabled: appliances run a self-signed
 *       management certificate and are frequently addressed by IP. This mirrors {@code curl -k} in
 *       the proven shell automation.</li>
 *   <li>Multipart uploads are assembled by hand because the JDK client has no multipart support;
 *       FortiWeb derives the stored certificate name from the uploaded <em>file name</em>, so the
 *       {@code filename=} parameter is significant.</li>
 * </ul>
 *
 * <p>FortiWeb sometimes answers HTTP 200 with an error payload
 * ({@code {"results":{"errcode":-5,"message":"…"}}}); {@link #errorMessage(String)} surfaces that so
 * callers can treat it as a failure.
 */
@Slf4j
public class FortiWebRestClient {

    private static final ObjectMapper MAPPER = new ObjectMapper();
    private static final Duration CONNECT_TIMEOUT = Duration.ofSeconds(30);
    private static final Duration REQUEST_TIMEOUT = Duration.ofSeconds(120);

    static {
        // Must be set before the first HttpClient is built; FortiWeb appliances are typically
        // reached by IP or a name that does not match their self-signed management certificate.
        System.setProperty("jdk.internal.httpclient.disableHostnameVerification", "true");
    }

    @Getter
    private final String baseUrl;
    private final String token;
    private final HttpClient httpClient;

    public FortiWebRestClient(AdapterConfig config) {
        this.baseUrl = config.apiBaseUrl();
        this.token = config.authorizationToken();
        this.httpClient = HttpClient.newBuilder()
                .connectTimeout(CONNECT_TIMEOUT)
                .proxy(ProxySelector.getDefault())
                .sslContext(trustAllContext())
                .version(HttpClient.Version.HTTP_1_1)
                .followRedirects(HttpClient.Redirect.NORMAL)
                .build();
    }

    // ------------------------------------------------------------------ verbs

    public HttpResponse<String> get(String path) throws IOException, InterruptedException {
        final var request = base(path).GET().build();
        return send("GET", path, request);
    }

    public HttpResponse<String> putJson(String path, String jsonBody) throws IOException, InterruptedException {
        final var request = base(path)
                .header("Content-Type", "application/json")
                .PUT(HttpRequest.BodyPublishers.ofString(jsonBody, StandardCharsets.UTF_8))
                .build();
        return send("PUT", path, request);
    }

    public HttpResponse<String> postJson(String path, String jsonBody) throws IOException, InterruptedException {
        final var request = base(path)
                .header("Content-Type", "application/json")
                .POST(HttpRequest.BodyPublishers.ofString(jsonBody, StandardCharsets.UTF_8))
                .build();
        return send("POST", path, request);
    }

    public HttpResponse<String> delete(String path) throws IOException, InterruptedException {
        final var request = base(path).DELETE().build();
        return send("DELETE", path, request);
    }

    /**
     * Sends a {@code multipart/form-data} POST. {@code fields} are plain form fields; {@code files}
     * maps a form field name to a (file name, content) pair — the file name is what FortiWeb turns
     * into the certificate object name.
     */
    public HttpResponse<String> postMultipart(String path, Map<String, String> fields,
                                              Map<String, FilePart> files)
            throws IOException, InterruptedException {
        final var boundary = "----TLMFortiWeb" + UUID.randomUUID().toString().replace("-", "");
        final var body = buildMultipart(boundary, fields, files);
        final var request = base(path)
                .header("Content-Type", "multipart/form-data; boundary=" + boundary)
                .POST(HttpRequest.BodyPublishers.ofByteArray(body))
                .build();
        return send("POST(multipart)", path, request);
    }

    // ------------------------------------------------------------------ helpers

    public static boolean isSuccess(HttpResponse<?> response) {
        return response.statusCode() >= 200 && response.statusCode() < 300;
    }

    /** Parses a body as JSON, or returns a missing node when it is not JSON. */
    public static JsonNode json(String body) {
        if (body == null || body.isBlank()) {
            return MAPPER.missingNode();
        }
        try {
            return MAPPER.readTree(body);
        } catch (IOException e) {
            return MAPPER.missingNode();
        }
    }

    /**
     * FortiWeb frequently reports failures inside a 2xx body:
     * {@code {"results":{"errcode":-N,"message":"..."}}} or {@code {"errcode":-N,...}}. Returns
     * that message when present (a negative errcode), otherwise null.
     */
    public static String errorMessage(String body) {
        final var root = json(body);
        if (root.isMissingNode()) {
            return null;
        }
        for (JsonNode candidate : new JsonNode[] { root.path("results"), root }) {
            // FortiWeb emits errcode sometimes as a number and sometimes as a string ("-20007").
            final var errcode = candidate.path("errcode");
            final Integer code = errcode.isNumber()
                    ? Integer.valueOf(errcode.asInt()) : parseIntOrNull(errcode.asText(null));
            if (code != null && code < 0) {
                final var message = candidate.path("message").asText(null);
                return "errcode " + code + (message != null ? ": " + message : "");
            }
        }
        return null;
    }

    private static Integer parseIntOrNull(String text) {
        if (text == null || text.isBlank()) {
            return null;
        }
        try {
            return Integer.parseInt(text.trim());
        } catch (NumberFormatException e) {
            return null;
        }
    }

    /** True when the HTTP status is 2xx and the body carries no FortiWeb error code. */
    public static boolean isFortiWebSuccess(HttpResponse<String> response) {
        return isSuccess(response) && errorMessage(response.body()) == null;
    }

    /** Human-readable failure summary for logs / TLM error messages. */
    public static String describeFailure(HttpResponse<String> response) {
        final var api = errorMessage(response.body());
        final var body = response.body() == null ? "" : response.body().trim();
        return "HTTP " + response.statusCode()
                + (api != null ? " (" + api + ")" : "")
                + (body.isEmpty() ? "" : " body=" + abbreviate(body, 600));
    }

    public static String urlEncode(String value) {
        return URLEncoder.encode(value, StandardCharsets.UTF_8);
    }

    /** A file to include in a multipart upload. */
    public record FilePart(String fileName, byte[] content, String contentType) {
        public static FilePart pem(String fileName, String pem) {
            return new FilePart(fileName, pem.getBytes(StandardCharsets.UTF_8), "application/x-pem-file");
        }
    }

    // ------------------------------------------------------------------ internals

    private HttpRequest.Builder base(String path) {
        final var url = path.startsWith("http") ? path : baseUrl + (path.startsWith("/") ? path : "/" + path);
        return HttpRequest.newBuilder()
                .uri(URI.create(url))
                .timeout(REQUEST_TIMEOUT)
                .header("Authorization", token)
                .header("Accept", "application/json");
    }

    private HttpResponse<String> send(String verb, String path, HttpRequest request)
            throws IOException, InterruptedException {
        log.info("{} {}", verb, request.uri());
        final var response = httpClient.send(request, HttpResponse.BodyHandlers.ofString(StandardCharsets.UTF_8));
        if (isSuccess(response)) {
            log.info("{} {} -> HTTP {}", verb, path, response.statusCode());
        } else {
            log.warn("{} {} -> HTTP {} body={}", verb, path, response.statusCode(),
                    abbreviate(response.body(), 600));
        }
        return response;
    }

    private static byte[] buildMultipart(String boundary, Map<String, String> fields,
                                         Map<String, FilePart> files) throws IOException {
        final var out = new ByteArrayOutputStream();
        final var crlf = "\r\n";
        for (var e : (fields == null ? Map.<String, String>of() : fields).entrySet()) {
            out.write(("--" + boundary + crlf).getBytes(StandardCharsets.UTF_8));
            out.write(("Content-Disposition: form-data; name=\"" + e.getKey() + "\"" + crlf + crlf)
                    .getBytes(StandardCharsets.UTF_8));
            out.write((e.getValue() == null ? "" : e.getValue()).getBytes(StandardCharsets.UTF_8));
            out.write(crlf.getBytes(StandardCharsets.UTF_8));
        }
        for (var e : (files == null ? Map.<String, FilePart>of() : files).entrySet()) {
            final var part = e.getValue();
            out.write(("--" + boundary + crlf).getBytes(StandardCharsets.UTF_8));
            out.write(("Content-Disposition: form-data; name=\"" + e.getKey() + "\"; filename=\""
                    + part.fileName() + "\"" + crlf).getBytes(StandardCharsets.UTF_8));
            out.write(("Content-Type: " + (part.contentType() == null
                    ? "application/octet-stream" : part.contentType()) + crlf + crlf)
                    .getBytes(StandardCharsets.UTF_8));
            out.write(part.content());
            out.write(crlf.getBytes(StandardCharsets.UTF_8));
        }
        out.write(("--" + boundary + "--" + crlf).getBytes(StandardCharsets.UTF_8));
        return out.toByteArray();
    }

    private static SSLContext trustAllContext() {
        try {
            final var trustAll = new TrustManager[] { new X509TrustManager() {
                @Override public void checkClientTrusted(X509Certificate[] c, String a) { }
                @Override public void checkServerTrusted(X509Certificate[] c, String a) { }
                @Override public X509Certificate[] getAcceptedIssuers() { return new X509Certificate[0]; }
            } };
            final var ctx = SSLContext.getInstance("TLS");
            ctx.init(null, trustAll, new SecureRandom());
            return ctx;
        } catch (Exception e) {
            throw new IllegalStateException("Failed to build trust-all SSLContext", e);
        }
    }

    private static String abbreviate(String value, int max) {
        if (value == null) {
            return "";
        }
        final var oneLine = value.replaceAll("\\s+", " ").trim();
        return oneLine.length() <= max ? oneLine : oneLine.substring(0, max) + "…";
    }

    /** Convenience for building ordered form-field maps. */
    public static Map<String, String> fields(String... kv) {
        final var map = new LinkedHashMap<String, String>();
        for (int i = 0; i + 1 < kv.length; i += 2) {
            map.put(kv[i], kv[i + 1]);
        }
        return map;
    }
}
