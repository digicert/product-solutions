package com.digicert.automation.f5xc.service.api.response;

import com.fasterxml.jackson.annotation.JsonIgnoreProperties;
import com.fasterxml.jackson.annotation.JsonProperty;
import lombok.Data;

/**
 * Response of {@code GET /api/config/namespaces/{namespace}/certificates/{name}}.
 * <p>
 * F5-XC stores the served certificate (chain) PEM in {@code spec.certificate_url} as
 * {@code string:///<base64-PEM>}. The private key is write-only and is never returned.
 * Only the fields needed by the plugin are modelled; unknown fields are ignored.
 *
 * @author michael.rudloff
 */
@Data
@JsonIgnoreProperties(ignoreUnknown = true)
public class CertificateObject {

    private Metadata metadata;
    private Spec spec;

    @Data
    @JsonIgnoreProperties(ignoreUnknown = true)
    public static class Metadata {
        private String name;
        private String namespace;
    }

    @Data
    @JsonIgnoreProperties(ignoreUnknown = true)
    public static class Spec {
        /** {@code string:///<base64-PEM>} of the certificate (chain). */
        @JsonProperty("certificate_url")
        private String certificateUrl;
    }
}
