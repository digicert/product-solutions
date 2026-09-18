package com.digicert.automation.f5xc.service;

import com.fasterxml.jackson.databind.JsonNode;

/**
 * Small shared helpers for reading custom request fields from the raw TLM request JSON.
 * <p>
 * In this SDK build the custom flow fields ({@code virtualServerName},
 * {@code certificateSerialNumber}, ...) are carried as flat properties on the request JSON
 * rather than typed getters on the request DTO, so they are read directly from the {@link JsonNode}.
 *
 * @author michael.rudloff
 */
final class ServiceSupport {

    private ServiceSupport() {
    }

    /**
     * Resolves the F5-XC certificate object name from the request's {@code virtualServerName}.
     * <p>
     * TLM supplies {@code virtualServerName} as {@code <namespace>/<certName>}; the trailing
     * segment is the certificate object name. A bare value (no {@code /}) is returned as-is.
     */
    static String certificateNameFrom(JsonNode request) {
        String virtualServerName = text(request, "virtualServerName");
        if (virtualServerName.isBlank()) {
            throw new IllegalArgumentException("virtualServerName is required (expected '<namespace>/<certName>')");
        }
        int slash = virtualServerName.lastIndexOf('/');
        return slash >= 0 ? virtualServerName.substring(slash + 1) : virtualServerName;
    }

    /** Reads a string property from the request JSON, returning {@code ""} when absent/null. */
    static String text(JsonNode request, String field) {
        if (request == null) {
            return "";
        }
        JsonNode node = request.get(field);
        return node == null || node.isNull() ? "" : node.asText();
    }
}
