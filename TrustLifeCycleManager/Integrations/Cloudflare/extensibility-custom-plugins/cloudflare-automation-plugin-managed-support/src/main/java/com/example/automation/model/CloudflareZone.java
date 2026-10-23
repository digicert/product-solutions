package com.example.automation.model;

import lombok.Data;

/** The Cloudflare zone a connector manages, as returned by {@code GET /zones/{zone_id}}. */
@Data
public class CloudflareZone {
    private String id;
    /** Apex domain name, e.g. {@code example.com}. */
    private String name;
    /** {@code active}, {@code pending}, {@code initializing} or {@code moved}. */
    private String status;
    /** {@code full}, {@code partial}, {@code secondary}. */
    private String type;
    private Boolean paused;
    private String accountId;
    private String accountName;
    private String planName;
}
