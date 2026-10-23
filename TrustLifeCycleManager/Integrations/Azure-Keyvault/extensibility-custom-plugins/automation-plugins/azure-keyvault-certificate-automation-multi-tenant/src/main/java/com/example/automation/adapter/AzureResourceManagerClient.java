package com.example.automation.adapter;

import java.net.URL;
import java.net.URLEncoder;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.List;
import java.util.Locale;
import java.util.Optional;
import java.util.regex.Pattern;
import java.util.regex.PatternSyntaxException;

import com.azure.core.credential.TokenCredential;
import com.azure.core.exception.HttpResponseException;
import com.azure.core.http.HttpMethod;
import com.azure.core.http.HttpPipeline;
import com.azure.core.http.HttpPipelineBuilder;
import com.azure.core.http.HttpRequest;
import com.azure.core.http.HttpResponse;
import com.azure.core.http.policy.BearerTokenAuthenticationPolicy;
import com.azure.core.http.policy.RetryPolicy;
import com.azure.core.util.Context;
import com.example.automation.model.KeyVaultInfo;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;

import lombok.extern.slf4j.Slf4j;

/**
 * Minimal Azure Resource Manager (ARM) client: lists the Key Vaults of one subscription and reads
 * the subscription's display name. It issues two plain REST calls over the same azure-core
 * {@link HttpPipeline} machinery the Key Vault SDK uses (Netty client, bearer-token policy, retry),
 * so no extra {@code azure-resourcemanager-*} dependency is shaded into the plugin.
 *
 * <p>Required permission: the <b>Reader</b> role (or any role carrying
 * {@code Microsoft.KeyVault/vaults/read}) on the subscription, or on each resource group named in
 * the connector's resource-group filter.
 */
@Slf4j
public class AzureResourceManagerClient {

    /** Azure public cloud ARM endpoint and token scope. */
    static final String ARM_ENDPOINT = "https://management.azure.com";
    static final String ARM_SCOPE = ARM_ENDPOINT + "/.default";

    private static final String VAULTS_API_VERSION = "2023-07-01";
    private static final String SUBSCRIPTION_API_VERSION = "2022-12-01";

    private static final ObjectMapper MAPPER = new ObjectMapper();

    private final AdapterConfig config;
    private final HttpPipeline pipeline;

    public AzureResourceManagerClient(AdapterConfig config, TokenCredential credential) {
        this.config = config;
        this.pipeline = new HttpPipelineBuilder()
                .httpClient(AzureCredentialsProvider.createHttpClientBuilder().build())
                .policies(new RetryPolicy(), new BearerTokenAuthenticationPolicy(credential, ARM_SCOPE))
                .build();
    }

    /**
     * Lists the Key Vaults of the configured subscription that pass the connector's filters
     * (resource groups, name pattern, tag). Follows ARM paging.
     */
    public List<KeyVaultInfo> listVaults() {
        final List<KeyVaultInfo> vaults = new ArrayList<>();
        final var scopes = new ArrayList<String>();
        if (config.getResourceGroups() == null || config.getResourceGroups().isEmpty()) {
            scopes.add("/subscriptions/" + enc(config.getSubscriptionId()));
        } else {
            for (String rg : config.getResourceGroups()) {
                scopes.add("/subscriptions/" + enc(config.getSubscriptionId())
                        + "/resourceGroups/" + enc(rg));
            }
        }

        final var namePattern = compileNamePattern(config.getVaultNamePattern());
        int skippedByFilter = 0;
        for (String scope : scopes) {
            String url = ARM_ENDPOINT + scope + "/providers/Microsoft.KeyVault/vaults?api-version="
                    + VAULTS_API_VERSION;
            while (url != null) {
                final JsonNode page = get(url);
                for (JsonNode node : page.path("value")) {
                    final var vault = toVault(node);
                    if (vault.getVaultUri() == null) {
                        log.warn("Skipping vault {} without a vaultUri in the ARM response", vault.getName());
                        continue;
                    }
                    if (!matchesFilters(vault, node, namePattern)) {
                        skippedByFilter++;
                        continue;
                    }
                    vaults.add(vault);
                }
                final var next = page.path("nextLink");
                url = next.isTextual() && !next.asText().isBlank() ? next.asText() : null;
            }
        }
        log.info("ARM listed {} Key Vault(s) in subscription {} ({} skipped by connector filters)",
                vaults.size(), config.getSubscriptionId(), skippedByFilter);
        return vaults;
    }

    /** Subscription display name, or empty when the principal cannot read the subscription resource. */
    public Optional<String> subscriptionDisplayName() {
        try {
            final var node = get(ARM_ENDPOINT + "/subscriptions/" + enc(config.getSubscriptionId())
                    + "?api-version=" + SUBSCRIPTION_API_VERSION);
            final var name = node.path("displayName");
            return name.isTextual() && !name.asText().isBlank() ? Optional.of(name.asText()) : Optional.empty();
        } catch (Exception e) {
            log.info("Subscription display name not readable ({}); using the id", e.getMessage());
            return Optional.empty();
        }
    }

    // ------------------------------------------------------------------ helpers

    private JsonNode get(String url) {
        final var request = new HttpRequest(HttpMethod.GET, toUrl(url));
        request.setHeader("Accept", "application/json");
        try (HttpResponse response = pipeline.sendSync(request, Context.NONE)) {
            final var body = response.getBodyAsBinaryData();
            final var text = body == null ? "" : body.toString();
            if (response.getStatusCode() / 100 != 2) {
                throw new HttpResponseException("ARM request failed: HTTP " + response.getStatusCode()
                        + " for " + url + (text.isBlank() ? "" : " — " + summarize(text)), response);
            }
            try {
                return MAPPER.readTree(text);
            } catch (Exception e) {
                throw new IllegalStateException("ARM returned an unparseable body for " + url, e);
            }
        }
    }

    private static URL toUrl(String url) {
        try {
            return new URL(url);
        } catch (Exception e) {
            throw new IllegalArgumentException("Invalid ARM URL " + url, e);
        }
    }

    private static KeyVaultInfo toVault(JsonNode node) {
        final var vault = new KeyVaultInfo();
        vault.setName(node.path("name").asText(null));
        vault.setResourceId(node.path("id").asText(null));
        vault.setLocation(node.path("location").asText(null));
        vault.setVaultUri(node.path("properties").path("vaultUri").asText(null));
        vault.setResourceGroup(resourceGroupOf(vault.getResourceId()));
        return vault;
    }

    /** {@code /subscriptions/<s>/resourceGroups/<rg>/providers/...} → {@code <rg>}. */
    static String resourceGroupOf(String resourceId) {
        if (resourceId == null) {
            return null;
        }
        final var parts = resourceId.split("/");
        for (int i = 0; i + 1 < parts.length; i++) {
            if (parts[i].equalsIgnoreCase("resourceGroups")) {
                return parts[i + 1];
            }
        }
        return null;
    }

    private boolean matchesFilters(KeyVaultInfo vault, JsonNode node, Pattern namePattern) {
        if (namePattern != null && (vault.getName() == null || !namePattern.matcher(vault.getName()).matches())) {
            log.info("Vault {} does not match the name pattern; skipped", vault.getName());
            return false;
        }
        final var tagFilter = config.getVaultTagFilter();
        if (tagFilter != null && !tagFilter.isBlank()) {
            final int eq = tagFilter.indexOf('=');
            final var key = (eq >= 0 ? tagFilter.substring(0, eq) : tagFilter).trim();
            final var value = eq >= 0 ? tagFilter.substring(eq + 1).trim() : null;
            final var tags = node.path("tags");
            String actual = null;
            final var fields = tags.fields();
            while (fields.hasNext()) {
                final var f = fields.next();
                if (f.getKey().equalsIgnoreCase(key)) {
                    actual = f.getValue().asText("");
                    break;
                }
            }
            final boolean ok = actual != null
                    && (value == null || value.isEmpty() || value.equalsIgnoreCase(actual));
            if (!ok) {
                log.info("Vault {} does not carry tag {}; skipped", vault.getName(), tagFilter);
                return false;
            }
        }
        return true;
    }

    private static Pattern compileNamePattern(String pattern) {
        if (pattern == null || pattern.isBlank()) {
            return null;
        }
        try {
            return Pattern.compile(pattern.trim(), Pattern.CASE_INSENSITIVE);
        } catch (PatternSyntaxException e) {
            throw new IllegalArgumentException("Invalid vault name pattern '" + pattern + "': "
                    + e.getDescription(), e);
        }
    }

    private static String enc(String s) {
        return URLEncoder.encode(s == null ? "" : s.trim(), StandardCharsets.UTF_8);
    }

    /** First ~300 characters of an ARM error body, lower-cased JSON noise trimmed. */
    private static String summarize(String body) {
        final var oneLine = body.replaceAll("\\s+", " ").trim();
        return oneLine.length() > 300 ? oneLine.substring(0, 300) + "…" : oneLine;
    }

    static String lower(String s) {
        return s == null ? null : s.toLowerCase(Locale.ROOT);
    }
}
