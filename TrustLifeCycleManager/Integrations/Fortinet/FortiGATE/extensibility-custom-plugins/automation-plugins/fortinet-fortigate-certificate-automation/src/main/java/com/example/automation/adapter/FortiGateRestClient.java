package com.example.automation.adapter;

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

import javax.net.ssl.SSLContext;
import javax.net.ssl.TrustManager;
import javax.net.ssl.X509TrustManager;

import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;

import lombok.Getter;
import lombok.extern.slf4j.Slf4j;

/**
 * Thin HTTP client for the FortiOS REST API ({@code /api/v2/cmdb/…} and {@code /api/v2/monitor/…})
 * built on the JDK {@link HttpClient}.
 *
 * <ul>
 *   <li>Every request carries {@code Authorization: Bearer <token>} — the REST API administrator's
 *       token.</li>
 *   <li>TLS is trust-all with hostname verification disabled: appliances run a factory or
 *       self-signed management certificate and are frequently addressed by IP. This mirrors
 *       {@code curl -k} in the proven shell automation.</li>
 *   <li>FortiOS answers every call with a JSON envelope
 *       ({@code {"http_method":…,"results":…,"vdom":…,"status":"success"|"error","http_status":…,
 *       "error":-N,"cli_error":"…"}}); {@link #errorMessage(String)} surfaces the error fields so
 *       callers can treat a {@code status: error} inside a 2xx as a failure.</li>
 * </ul>
 */
@Slf4j
public class FortiGateRestClient {

    private static final ObjectMapper MAPPER = new ObjectMapper();
    private static final Duration CONNECT_TIMEOUT = Duration.ofSeconds(30);
    private static final Duration REQUEST_TIMEOUT = Duration.ofSeconds(120);

    static {
        // Must be set before the first HttpClient is built; FortiGates are typically reached by IP
        // or a name that does not match their management certificate.
        System.setProperty("jdk.internal.httpclient.disableHostnameVerification", "true");
    }

    @Getter
    private final String baseUrl;
    private final String token;
    private final HttpClient httpClient;

    public FortiGateRestClient(AdapterConfig config) {
        this.baseUrl = config.apiBaseUrl();
        this.token = config.getApiToken();
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
     * FortiOS reports failures in its envelope: {@code "status":"error"} together with a negative
     * {@code error} code and often a {@code cli_error} text (occasionally inside an HTTP 200).
     * Returns a description when present, otherwise null.
     */
    public static String errorMessage(String body) {
        final var root = json(body);
        if (root.isMissingNode() || !root.isObject()) {
            return null;
        }
        final var status = root.path("status").asText("");
        final var error = root.path("error");
        final Integer code = error.isNumber() ? Integer.valueOf(error.asInt()) : parseIntOrNull(error.asText(null));
        if (!"error".equalsIgnoreCase(status) && (code == null || code >= 0)) {
            return null;
        }
        final var sb = new StringBuilder("status=error");
        if (code != null) {
            sb.append(" error=").append(code);
        }
        final var cli = root.path("cli_error").asText(null);
        if (cli != null && !cli.isBlank()) {
            sb.append(" cli_error=").append(cli.trim());
        }
        final var message = root.path("message").asText(null);
        if (message != null && !message.isBlank()) {
            sb.append(" message=").append(message.trim());
        }
        return sb.toString();
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

    /** True when the HTTP status is 2xx and the envelope carries no FortiOS error. */
    public static boolean isFortiGateSuccess(HttpResponse<String> response) {
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
        return URLEncoder.encode(value, StandardCharsets.UTF_8).replace("+", "%20");
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
                .header("Accept", "application/json");
    }

    private HttpResponse<String> send(String verb, String path, HttpRequest request)
            throws IOException, InterruptedException {
        log.info("{} {}", verb, request.uri());
        final HttpResponse<String> response;
        try {
            response = httpClient.send(request, HttpResponse.BodyHandlers.ofString(StandardCharsets.UTF_8));
        } catch (javax.net.ssl.SSLException e) {
            final var msg = e.getMessage() == null ? "" : e.getMessage();
            if (msg.contains("plaintext")) {
                throw new IOException("Port " + request.uri().getPort() + " on " + request.uri().getHost()
                        + " does not speak TLS (" + msg + "). The REST API port must be the FortiGate's HTTPS "
                        + "administrative-access port (usually 443), not the SSH port.", e);
            }
            throw e;
        } catch (java.net.ConnectException | java.net.http.HttpConnectTimeoutException e) {
            // The JDK client often throws these with a null message, which reaches TLM as a bare
            // class name; say what was attempted instead.
            throw new IOException("Cannot connect to " + request.uri().getHost() + ":" + request.uri().getPort()
                    + " (connection refused, timed out or unreachable" + (e.getMessage() == null ? "" : ": " + e.getMessage())
                    + "). Check the FortiGate host, the HTTPS administrative-access port, and that the sensor's "
                    + "address is allowed to reach it.", e);
        } catch (java.net.UnknownHostException e) {
            throw new IOException("Cannot resolve FortiGate host '" + request.uri().getHost() + "' from the sensor.", e);
        }
        if (isFortiGateSuccess(response)) {
            log.info("{} {} -> HTTP {}", verb, path, response.statusCode());
        } else {
            log.warn("{} {} -> HTTP {} body={}", verb, path, response.statusCode(),
                    abbreviate(response.body(), 600));
        }
        return response;
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

    static String abbreviate(String value, int max) {
        if (value == null) {
            return "";
        }
        final var oneLine = value.replaceAll("\\s+", " ").trim();
        return oneLine.length() <= max ? oneLine : oneLine.substring(0, max) + "…";
    }
}
