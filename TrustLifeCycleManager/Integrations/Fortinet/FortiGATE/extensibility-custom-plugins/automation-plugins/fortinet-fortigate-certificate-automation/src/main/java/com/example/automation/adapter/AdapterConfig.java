package com.example.automation.adapter;

import java.net.URLEncoder;
import java.nio.charset.StandardCharsets;

import lombok.Builder;
import lombok.Data;

/**
 * Connection settings for a single FortiGate (FortiOS) appliance, built from the TLM connector
 * configuration.
 *
 * <p>The FortiOS REST API ({@code /api/v2}) authenticates every request with
 * {@code Authorization: Bearer <token>}, where the token belongs to a <em>REST API administrator</em>
 * created on the FortiGate (System → Administrators → REST API Admin). Everything the plugin needs,
 * certificate bodies included, is available over that API, so no CLI/SSH account is required.
 *
 * <p>FortiOS keeps local certificates either in the <b>global</b> scope (the default for anything
 * imported through the GUI or the import API with {@code scope=global}) or inside a VDOM. Every
 * certificate call therefore carries {@link #certificateScopeQuery()} — {@code scope=global} or
 * {@code vdom=<name>} — while object references (SSL-VPN settings, IPsec tunnels, VIPs…) always
 * live in a VDOM and use {@link #vdomQuery()}.
 */
@Data
@Builder
public class AdapterConfig {

    public static final int DEFAULT_PORT = 443;
    public static final String DEFAULT_VDOM = "root";
    public static final String SCOPE_GLOBAL = "global";
    public static final String SCOPE_VDOM = "vdom";

    /** Management host — bare FQDN or IP (no scheme, path or port). */
    private String host;

    /** REST API (HTTPS administrative access) port; 443 on a default appliance. */
    private int port;

    /** REST API administrator token, sent as {@code Authorization: Bearer}. Never logged. */
    private String apiToken;

    /** VDOM the connector works in ({@code root} unless VDOMs are in use). */
    private String vdom;

    /** {@link #SCOPE_GLOBAL} (default) or {@link #SCOPE_VDOM}: where the managed certificates live. */
    private String certificateScope;

    /**
     * When true the plugin leaves the replaced certificate on the appliance after repointing every
     * reference to the new one; when false (default) it deletes it once FortiGate reports it as
     * unreferenced.
     */
    private boolean keepReplacedCertificate;

    /** Base URL of the REST API, e.g. {@code https://fgt.example.com:443/api/v2}. */
    public String apiBaseUrl() {
        return "https://" + host + ":" + port + "/api/v2";
    }

    public String effectiveVdom() {
        return vdom == null || vdom.isBlank() ? DEFAULT_VDOM : vdom.trim();
    }

    public boolean isGlobalScope() {
        return certificateScope == null || certificateScope.isBlank()
                || SCOPE_GLOBAL.equalsIgnoreCase(certificateScope.trim());
    }

    /** Query fragment (without {@code ?}) selecting the certificate scope: {@code scope=global} or {@code vdom=<name>}. */
    public String certificateScopeQuery() {
        return isGlobalScope() ? "scope=global" : vdomQuery();
    }

    /** {@code scope} value the import API expects: {@code global} or {@code vdom}. */
    public String importScope() {
        return isGlobalScope() ? SCOPE_GLOBAL : SCOPE_VDOM;
    }

    /** Query fragment (without {@code ?}) selecting the VDOM for object references. */
    public String vdomQuery() {
        return "vdom=" + URLEncoder.encode(effectiveVdom(), StandardCharsets.UTF_8);
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
