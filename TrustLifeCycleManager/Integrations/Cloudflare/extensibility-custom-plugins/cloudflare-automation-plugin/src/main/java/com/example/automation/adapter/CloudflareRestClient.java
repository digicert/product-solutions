package com.example.automation.adapter;

import java.io.IOException;
import java.net.ProxySelector;
import java.net.URI;
import java.net.URLEncoder;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.nio.charset.StandardCharsets;
import java.time.Duration;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;

import lombok.Getter;
import lombok.extern.slf4j.Slf4j;

/**
 * Thin HTTP client for the Cloudflare v4 API built on the JDK {@link HttpClient}.
 *
 * <ul>
 *   <li>Every request carries {@code Authorization: Bearer <API token>}.</li>
 *   <li>TLS uses the JDK default trust store: {@code api.cloudflare.com} presents a publicly
 *       trusted certificate, so no trust-all shortcut is needed (or wanted). JVM proxy system
 *       properties are honoured.</li>
 *   <li>Cloudflare answers every call with a JSON envelope
 *       ({@code {"success":true|false,"errors":[{"code":…,"message":…}],"messages":[…],"result":…,
 *       "result_info":{…}}}); {@link #errorMessage(String)} surfaces the error list so callers can
 *       treat {@code success:false} as a failure even inside a 2xx.</li>
 *   <li>A 429 (rate limit) or 5xx is retried once after a short pause.</li>
 * </ul>
 */
@Slf4j
public class CloudflareRestClient {

    private static final ObjectMapper MAPPER = new ObjectMapper();
    private static final Duration CONNECT_TIMEOUT = Duration.ofSeconds(20);
    private static final Duration REQUEST_TIMEOUT = Duration.ofSeconds(60);
    private static final long RETRY_PAUSE_MILLIS = 2_000L;

    @Getter
    private final String baseUrl;
    private final String token;
    private final HttpClient httpClient;

    public CloudflareRestClient(AdapterConfig config) {
        this.baseUrl = config.effectiveApiBaseUrl();
        this.token = config.getApiToken();
        this.httpClient = HttpClient.newBuilder()
                .connectTimeout(CONNECT_TIMEOUT)
                .proxy(ProxySelector.getDefault())
                .version(HttpClient.Version.HTTP_1_1)
                .followRedirects(HttpClient.Redirect.NORMAL)
                .build();
    }

    // ------------------------------------------------------------------ verbs

    public HttpResponse<String> get(String path) throws IOException, InterruptedException {
        return send("GET", path, base(path).GET().build());
    }

    public HttpResponse<String> postJson(String path, String jsonBody) throws IOException, InterruptedException {
        return send("POST", path, base(path)
                .header("Content-Type", "application/json")
                .POST(HttpRequest.BodyPublishers.ofString(jsonBody, StandardCharsets.UTF_8))
                .build());
    }

    public HttpResponse<String> patchJson(String path, String jsonBody) throws IOException, InterruptedException {
        return send("PATCH", path, base(path)
                .header("Content-Type", "application/json")
                .method("PATCH", HttpRequest.BodyPublishers.ofString(jsonBody, StandardCharsets.UTF_8))
                .build());
    }

    public HttpResponse<String> putJson(String path, String jsonBody) throws IOException, InterruptedException {
        return send("PUT", path, base(path)
                .header("Content-Type", "application/json")
                .PUT(HttpRequest.BodyPublishers.ofString(jsonBody, StandardCharsets.UTF_8))
                .build());
    }

    public HttpResponse<String> delete(String path) throws IOException, InterruptedException {
        return send("DELETE", path, base(path).DELETE().build());
    }

    // ------------------------------------------------------------------ helpers

    public static boolean isHttpSuccess(HttpResponse<?> response) {
        return response.statusCode() >= 200 && response.statusCode() < 300;
    }

    /** True when the HTTP status is 2xx and the envelope does not say {@code success: false}. */
    public static boolean isCloudflareSuccess(HttpResponse<String> response) {
        if (!isHttpSuccess(response)) {
            return false;
        }
        final var root = json(response.body());
        return !root.isObject() || !root.path("success").isBoolean() || root.path("success").asBoolean();
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

    /** The envelope's {@code result} node (missing node when absent). */
    public static JsonNode result(HttpResponse<String> response) {
        return json(response.body()).path("result");
    }

    /**
     * Cloudflare reports failures as {@code "success": false} together with an {@code errors} array
     * of {@code {code, message}} objects. Returns a description when present, otherwise null.
     */
    public static String errorMessage(String body) {
        final var root = json(body);
        if (root.isMissingNode() || !root.isObject()) {
            return null;
        }
        final var success = root.path("success");
        final var errors = root.path("errors");
        if ((!success.isBoolean() || success.asBoolean()) && (!errors.isArray() || errors.isEmpty())) {
            return null;
        }
        final var sb = new StringBuilder("success=false");
        if (errors.isArray()) {
            for (JsonNode e : errors) {
                sb.append("; ");
                if (e.has("code")) {
                    sb.append("code ").append(e.path("code").asText()).append(": ");
                }
                sb.append(e.path("message").asText(e.toString()));
            }
        }
        return sb.toString();
    }

    /** Human-readable failure summary for logs / TLM error messages. */
    public static String describeFailure(HttpResponse<String> response) {
        final var api = errorMessage(response.body());
        final var body = response.body() == null ? "" : response.body().trim();
        return "HTTP " + response.statusCode()
                + (api != null ? " (" + api + ")" : "")
                + (body.isEmpty() || api != null ? "" : " body=" + abbreviate(body, 600));
    }

    /** True when the envelope carries the given Cloudflare error code. */
    public static boolean hasErrorCode(HttpResponse<String> response, int code) {
        for (JsonNode e : json(response.body()).path("errors")) {
            if (e.path("code").asInt(-1) == code) {
                return true;
            }
        }
        return false;
    }

    public static String urlEncode(String value) {
        return URLEncoder.encode(value == null ? "" : value, StandardCharsets.UTF_8).replace("+", "%20");
    }

    /** Appends a query fragment ({@code a=b}) to a path that may or may not already carry a query. */
    public static String withQuery(String path, String query) {
        if (query == null || query.isBlank()) {
            return path;
        }
        return path + (path.contains("?") ? "&" : "?") + query;
    }

    // ------------------------------------------------------------------ internals

    private HttpRequest.Builder base(String path) {
        final var url = path.startsWith("http") ? path : baseUrl + (path.startsWith("/") ? path : "/" + path);
        return HttpRequest.newBuilder()
                .uri(URI.create(url))
                .timeout(REQUEST_TIMEOUT)
                .header("Authorization", "Bearer " + token)
                .header("Accept", "application/json")
                .header("User-Agent", "DigiCert-TLM-CloudflareAutomationPlugin/1.0");
    }

    private HttpResponse<String> send(String verb, String path, HttpRequest request)
            throws IOException, InterruptedException {
        log.info("{} {}", verb, request.uri());
        HttpResponse<String> response = doSend(request);
        if (response.statusCode() == 429 || response.statusCode() >= 500) {
            log.warn("{} {} -> HTTP {}; retrying once after {} ms", verb, path, response.statusCode(), RETRY_PAUSE_MILLIS);
            Thread.sleep(RETRY_PAUSE_MILLIS);
            response = doSend(request);
        }
        if (isCloudflareSuccess(response)) {
            log.info("{} {} -> HTTP {}", verb, path, response.statusCode());
        } else {
            log.warn("{} {} -> HTTP {} body={}", verb, path, response.statusCode(), abbreviate(response.body(), 600));
        }
        return response;
    }

    private HttpResponse<String> doSend(HttpRequest request) throws IOException, InterruptedException {
        try {
            return httpClient.send(request, HttpResponse.BodyHandlers.ofString(StandardCharsets.UTF_8));
        } catch (java.net.ConnectException | java.net.http.HttpConnectTimeoutException e) {
            throw new IOException("Cannot connect to " + request.uri().getHost()
                    + " (connection refused, timed out or unreachable" + (e.getMessage() == null ? "" : ": " + e.getMessage())
                    + "). The sensor needs outbound HTTPS access to the Cloudflare API; check firewall and proxy settings.", e);
        } catch (java.net.UnknownHostException e) {
            throw new IOException("Cannot resolve '" + request.uri().getHost() + "' from the sensor (DNS).", e);
        }
    }

    static String abbreviate(String value, int max) {
        if (value == null) {
            return "";
        }
        final var oneLine = value.replaceAll("\\s+", " ").trim();
        return oneLine.length() <= max ? oneLine : oneLine.substring(0, max) + "…";
    }
}
