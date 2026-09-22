package com.digicert.automation.f5xc.service.api;

import com.digicert.automation.extended.configuration.F5XCPluginConfiguration;
import lombok.Getter;
import lombok.extern.slf4j.Slf4j;

import java.io.IOException;
import java.net.ProxySelector;
import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.time.Duration;

/**
 * REST client for the F5 Distributed Cloud (F5-XC) API.
 * <p>
 * Uses Java 17's built-in {@link HttpClient}. Every request carries the
 * {@code Authorization: APIToken <token>} header sourced from the supplied
 * {@link F5XCPluginConfiguration}. The API base URL is derived from the tenant short name
 * as {@code https://<tenant>.console.ves.volterra.io}.
 *
 * @author michael.rudloff
 */
@Slf4j
public class RestClient {

    private static final String HEADER_AUTHORIZATION = "Authorization";
    private static final String HEADER_CONTENT_TYPE = "Content-Type";
    private static final String HEADER_ACCEPT = "Accept";
    private static final String APPLICATION_JSON = "application/json";

    private static final int CONNECT_TIMEOUT_SECONDS = 30;
    private static final int REQUEST_TIMEOUT_SECONDS = 60;

    private final HttpClient httpClient;
    private final String apiToken;

    @Getter
    private final String baseUrl;

    /**
     * Constructs a {@code RestClient} from the supplied {@link F5XCPluginConfiguration}.
     *
     * @param configuration the plugin configuration holding {@code tenant} and {@code apiToken}
     */
    public RestClient(F5XCPluginConfiguration configuration) {
        this.apiToken = configuration.getApiToken();
        this.baseUrl = buildBaseUrl(configuration.getTenant());
        this.httpClient = HttpClient.newBuilder()
                .connectTimeout(Duration.ofSeconds(CONNECT_TIMEOUT_SECONDS))
                .proxy(ProxySelector.getDefault())
                .build();
    }

    /**
     * Builds the F5-XC console base URL from the tenant short name. If a full URL is supplied
     * (starts with {@code http}) it is used verbatim, allowing tenants with custom domains.
     */
    static String buildBaseUrl(String tenant) {
        if (tenant == null || tenant.isBlank()) {
            throw new IllegalArgumentException("F5-XC tenant must be configured");
        }
        String trimmed = tenant.trim();
        if (trimmed.startsWith("http://") || trimmed.startsWith("https://")) {
            return trimmed.endsWith("/") ? trimmed.substring(0, trimmed.length() - 1) : trimmed;
        }
        return "https://" + trimmed + ".console.ves.volterra.io";
    }

    // -------------------------------------------------------------------------
    // Public HTTP methods
    // -------------------------------------------------------------------------

    public HttpResponse<String> get(String endpoint) throws IOException, InterruptedException {
        HttpRequest request = baseRequestBuilder(endpoint).GET().build();
        log.info("Sending GET request to: {}", resolve(endpoint));
        HttpResponse<String> response = httpClient.send(request, HttpResponse.BodyHandlers.ofString());
        logResponse("GET", endpoint, response.statusCode());
        return response;
    }

    public HttpResponse<String> post(String endpoint, String body) throws IOException, InterruptedException {
        HttpRequest request = baseRequestBuilder(endpoint)
                .header(HEADER_CONTENT_TYPE, APPLICATION_JSON)
                .POST(HttpRequest.BodyPublishers.ofString(body))
                .build();
        log.info("Sending POST request to: {}", resolve(endpoint));
        HttpResponse<String> response = httpClient.send(request, HttpResponse.BodyHandlers.ofString());
        logResponse("POST", endpoint, response.statusCode());
        return response;
    }

    public HttpResponse<String> put(String endpoint, String body) throws IOException, InterruptedException {
        HttpRequest request = baseRequestBuilder(endpoint)
                .header(HEADER_CONTENT_TYPE, APPLICATION_JSON)
                .PUT(HttpRequest.BodyPublishers.ofString(body))
                .build();
        log.info("Sending PUT request to: {}", resolve(endpoint));
        HttpResponse<String> response = httpClient.send(request, HttpResponse.BodyHandlers.ofString());
        logResponse("PUT", endpoint, response.statusCode());
        return response;
    }

    public HttpResponse<String> delete(String endpoint) throws IOException, InterruptedException {
        HttpRequest request = baseRequestBuilder(endpoint).DELETE().build();
        log.info("Sending DELETE request to: {}", resolve(endpoint));
        HttpResponse<String> response = httpClient.send(request, HttpResponse.BodyHandlers.ofString());
        logResponse("DELETE", endpoint, response.statusCode());
        return response;
    }

    // -------------------------------------------------------------------------
    // Utility helpers
    // -------------------------------------------------------------------------

    /** Throws {@link IllegalStateException} when the response status is not 2xx. */
    public void validateHttpResponseStatus(HttpResponse<String> response) {
        if (!isSuccessful(response.statusCode())) {
            throw new IllegalStateException(
                    "F5-XC API returned status code " + response.statusCode() + " with body: " + response.body());
        }
    }

    public boolean isSuccessful(int statusCode) {
        return statusCode >= 200 && statusCode < 300;
    }

    // -------------------------------------------------------------------------
    // Private helpers
    // -------------------------------------------------------------------------

    private HttpRequest.Builder baseRequestBuilder(String endpoint) {
        return HttpRequest.newBuilder()
                .uri(URI.create(resolve(endpoint)))
                .header(HEADER_AUTHORIZATION, "APIToken " + apiToken)
                .header(HEADER_ACCEPT, APPLICATION_JSON)
                .timeout(Duration.ofSeconds(REQUEST_TIMEOUT_SECONDS));
    }

    private String resolve(String endpoint) {
        String path = endpoint.startsWith("/") ? endpoint : "/" + endpoint;
        return baseUrl + path;
    }

    private void logResponse(String method, String endpoint, int statusCode) {
        if (isSuccessful(statusCode)) {
            log.info("{} {} -> HTTP {}", method, endpoint, statusCode);
        } else {
            log.warn("{} {} -> HTTP {} (non-2xx)", method, endpoint, statusCode);
        }
    }
}
