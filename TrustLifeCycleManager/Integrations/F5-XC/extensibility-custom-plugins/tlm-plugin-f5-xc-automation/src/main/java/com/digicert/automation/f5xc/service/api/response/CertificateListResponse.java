package com.digicert.automation.f5xc.service.api.response;

import com.fasterxml.jackson.annotation.JsonIgnoreProperties;
import lombok.Data;

import java.util.ArrayList;
import java.util.List;

/**
 * Response of {@code GET /api/config/namespaces/{namespace}/certificates}.
 * <p>
 * Only the fields needed by the plugin are modelled; unknown fields are ignored.
 *
 * @author michael.rudloff
 */
@Data
@JsonIgnoreProperties(ignoreUnknown = true)
public class CertificateListResponse {

    private List<Item> items = new ArrayList<>();

    /** A single certificate object entry in the collection listing. */
    @Data
    @JsonIgnoreProperties(ignoreUnknown = true)
    public static class Item {
        private String name;
        private String namespace;
    }
}
