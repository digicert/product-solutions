package com.digicert.automation.f5xc.service.api;

import lombok.extern.slf4j.Slf4j;

import java.net.InetAddress;
import java.net.URI;

/**
 * Lightweight DNS helpers used to populate the IP/host fields of the TLM discovery response.
 * <p>
 * F5-XC certificate objects are not bound to an appliance IP; these helpers resolve the
 * API console host (for {@code managementIp}/{@code hostName}) and, best-effort, a
 * certificate's common name (for {@code dataIp}/{@code ipAddress}). Resolution failures
 * return an empty string rather than aborting discovery.
 *
 * @author michael.rudloff
 */
@Slf4j
public class NetworkApiAdapter {

    private NetworkApiAdapter() {
    }

    /**
     * Resolves the IP address of the host embedded in {@code urlOrHost} via local DNS.
     *
     * @param urlOrHost a full URL (e.g. {@code https://tenant.console.ves.volterra.io}) or bare host
     * @return dotted-decimal IPv4/IPv6 address, or {@code ""} on failure
     */
    public static String getIp(String urlOrHost) {
        try {
            String hostname = extractHostname(urlOrHost);
            String ip = InetAddress.getByName(hostname).getHostAddress();
            log.info("[getIp] Resolved '{}' -> {}", hostname, ip);
            return ip;
        } catch (Exception e) {
            log.warn("[getIp] Failed to resolve IP for '{}': {}", urlOrHost, e.getMessage());
            return "";
        }
    }

    /**
     * Extracts the hostname from {@code urlOrHost} without performing any network I/O.
     *
     * @param urlOrHost a full URL or bare host
     * @return the bare hostname, or {@code ""} if parsing fails
     */
    public static String getHostname(String urlOrHost) {
        try {
            String hostname = extractHostname(urlOrHost);
            log.info("[getHostname] Extracted hostname from '{}' -> {}", urlOrHost, hostname);
            return hostname;
        } catch (Exception e) {
            log.warn("[getHostname] Failed to extract hostname from '{}': {}", urlOrHost, e.getMessage());
            return "";
        }
    }

    private static String extractHostname(String urlOrHost) {
        if (urlOrHost == null || urlOrHost.isBlank()) {
            throw new IllegalArgumentException("URL/host is null or blank");
        }
        if (!urlOrHost.startsWith("http://") && !urlOrHost.startsWith("https://")) {
            return urlOrHost;
        }
        URI uri = URI.create(urlOrHost);
        String host = uri.getHost();
        if (host == null || host.isBlank()) {
            throw new IllegalArgumentException("Unable to extract hostname from URL: " + urlOrHost);
        }
        return host;
    }
}
