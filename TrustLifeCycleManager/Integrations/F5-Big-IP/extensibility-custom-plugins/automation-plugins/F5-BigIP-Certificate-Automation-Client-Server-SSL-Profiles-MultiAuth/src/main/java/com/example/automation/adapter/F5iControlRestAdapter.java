package com.example.automation.adapter;

import java.io.IOException;
import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.security.SecureRandom;
import java.security.cert.X509Certificate;
import java.time.Duration;
import java.util.Base64;
import java.util.Optional;

import javax.net.ssl.SSLContext;
import javax.net.ssl.SSLParameters;
import javax.net.ssl.TrustManager;
import javax.net.ssl.X509TrustManager;

import com.example.automation.model.Connection;
import com.example.automation.model.ErrorCode;
import com.example.automation.model.Result;

import lombok.extern.slf4j.Slf4j;

/**
 * Performs F5 iControl REST calls. Currently used only for testConnection, which validates that
 * basic-auth credentials work against {@code /mgmt/tm/sys/version}. Built on the JDK HttpClient so
 * the plugin keeps a small dependency footprint.
 */
@Slf4j
public class F5iControlRestAdapter {

    private static final Duration TIMEOUT = Duration.ofSeconds(30);
    private static final int HTTP_UNAUTHORIZED = 401;

    private final AdapterConfig config;
    private final HttpClient httpClient;
    private final String baseUrl;
    private final String basicAuthHeader;

    public F5iControlRestAdapter(AdapterConfig config) {
        this.config = config;
        final var protocol = Optional.ofNullable(config.getProtocol()).orElse("https");
        final var port = Optional.ofNullable(config.getPort()).orElse("443");
        this.baseUrl = String.format("%s://%s:%s", protocol, config.getHost(), port);
        this.basicAuthHeader = "Basic " + Base64.getEncoder()
                .encodeToString((config.getUsername() + ":" + config.getPassword())
                        .getBytes(java.nio.charset.StandardCharsets.UTF_8));
        this.httpClient = buildHttpClient();
    }

    public Result<Connection> testConnection() {
        final HttpResponse<String> response;
        try {
            final var request = HttpRequest.newBuilder()
                    .uri(URI.create(baseUrl + "/mgmt/tm/sys/version"))
                    .timeout(TIMEOUT)
                    .header("Accept", "application/json")
                    .header("Authorization", basicAuthHeader)
                    .GET()
                    .build();
            response = httpClient.send(request, HttpResponse.BodyHandlers.ofString());
        } catch (IOException | InterruptedException e) {
            if (e instanceof InterruptedException) {
                Thread.currentThread().interrupt();
            }
            log.error("Error sending /mgmt/tm/sys/version request to {}", config.getHost(), e);
            return Result.failure(e.getMessage(), ErrorCode.INTERNAL_ERROR.name());
        }

        if (response.statusCode() >= 200 && response.statusCode() < 300) {
            return Result.success(new Connection(true));
        }
        if (response.statusCode() == HTTP_UNAUTHORIZED) {
            log.error("Unauthorized response from /mgmt/tm/sys/version on host {}", config.getHost());
            return Result.failure("Unauthorized", ErrorCode.UNAUTHORIZED.name());
        }
        log.error("HTTP {} from /mgmt/tm/sys/version on host {}: {}",
                response.statusCode(), config.getHost(), response.body());
        return Result.failure("Internal error", ErrorCode.INTERNAL_ERROR.name());
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

            // Disable hostname/IP verification. F5 BIG-IPs typically have self-signed certs
            // with no SAN entry matching the management IP, which would otherwise trip
            // SSLHandshakeException("No subject alternative names present").
            final var sslParams = new SSLParameters();
            sslParams.setEndpointIdentificationAlgorithm(null);

            return HttpClient.newBuilder()
                    .connectTimeout(TIMEOUT)
                    .sslContext(ctx)
                    .sslParameters(sslParams)
                    .version(HttpClient.Version.HTTP_1_1)
                    .build();
        } catch (Exception e) {
            throw new IllegalStateException("Failed to build trust-all HttpClient", e);
        }
    }
}
