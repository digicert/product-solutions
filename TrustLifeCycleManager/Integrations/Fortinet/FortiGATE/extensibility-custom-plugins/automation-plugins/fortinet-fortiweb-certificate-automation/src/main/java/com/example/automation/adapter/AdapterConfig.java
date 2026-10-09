package com.example.automation.adapter;

import java.nio.charset.StandardCharsets;
import java.util.Base64;

import lombok.Builder;
import lombok.Data;

/**
 * Connection settings for a single FortiWeb appliance, built from the TLM connector configuration.
 *
 * <p>FortiWeb's REST API authenticates every request with an {@code Authorization} header whose
 * value is the base64 encoding of {@code {"username":"…","password":"…","vdom":"…"}}. The plugin
 * builds that token from the username / password / ADOM the operator entered, so the connector never
 * asks for a pre-encoded token (see {@link #authorizationToken()}).
 */
@Data
@Builder
public class AdapterConfig {

    public static final int DEFAULT_PORT = 443;
    public static final int DEFAULT_SSH_PORT = 22;
    public static final String DEFAULT_VDOM = "root";

    /** Management host — bare FQDN or IP (no scheme, path or port). */
    private String host;

    /** REST API port (443 on a default appliance; the example lab uses 8443). */
    private int port;

    private String username;
    private String password;

    /** FortiWeb ADOM ("vdom" in the token); {@code root} unless ADOMs are in use. */
    private String vdom;

    /**
     * SSH port of the management interface for the read-only CLI call that fetches certificate
     * bodies (default {@value #DEFAULT_SSH_PORT}); {@code null} disables SSH (discovery is then
     * metadata-only unless a certificate is bound to a policy that can be reached over TLS).
     */
    private Integer sshPort;

    public boolean isSshEnabled() {
        return sshPort != null && sshPort > 0;
    }

    /**
     * When true the plugin leaves the replaced certificate on the appliance after repointing every
     * reference to the new one; when false (default) it deletes it once FortiWeb reports it as
     * unreferenced.
     */
    private boolean keepReplacedCertificate;

    /** Base URL of the REST API, e.g. {@code https://fwb.example.com:8443/api/v2.0}. */
    public String apiBaseUrl() {
        return "https://" + host + ":" + port + "/api/v2.0";
    }

    /** FortiWeb API token: base64 of the credential JSON. Never log the result. */
    public String authorizationToken() {
        final var json = "{\"username\":\"" + jsonEscape(username) + "\","
                + "\"password\":\"" + jsonEscape(password) + "\","
                + "\"vdom\":\"" + jsonEscape(vdom == null || vdom.isBlank() ? DEFAULT_VDOM : vdom) + "\"}";
        return Base64.getEncoder().encodeToString(json.getBytes(StandardCharsets.UTF_8));
    }

    private static String jsonEscape(String value) {
        if (value == null) {
            return "";
        }
        final var sb = new StringBuilder(value.length() + 8);
        for (char c : value.toCharArray()) {
            switch (c) {
                case '"' -> sb.append("\\\"");
                case '\\' -> sb.append("\\\\");
                case '\n' -> sb.append("\\n");
                case '\r' -> sb.append("\\r");
                case '\t' -> sb.append("\\t");
                default -> {
                    if (c < 0x20) {
                        sb.append(String.format("\\u%04x", (int) c));
                    } else {
                        sb.append(c);
                    }
                }
            }
        }
        return sb.toString();
    }

    /**
     * Reduces whatever the operator typed for the host to a bare host: strips any scheme(s), path,
     * trailing slash and an explicit {@code :port} (the port is a separate connector field). So
     * {@code host}, {@code https://host}, {@code http://host/} and {@code host:8443} all work.
     */
    public static String normalizeHost(String raw) {
        if (raw == null) {
            return null;
        }
        var host = raw.trim();
        while (host.contains("://")) {
            host = host.substring(host.indexOf("://") + 3);
        }
        final int slash = host.indexOf('/');
        if (slash >= 0) {
            host = host.substring(0, slash);
        }
        // Drop a trailing :port, but leave IPv6 literals ([::1]) alone.
        if (!host.startsWith("[")) {
            host = host.replaceFirst(":[0-9]+$", "");
        }
        return host.isBlank() ? null : host;
    }
}
