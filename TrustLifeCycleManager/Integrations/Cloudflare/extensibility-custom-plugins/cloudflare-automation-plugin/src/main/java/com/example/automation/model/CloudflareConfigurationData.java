package com.example.automation.model;

import java.util.ArrayList;
import java.util.List;

import lombok.Data;

/**
 * Aggregated inventory pulled from Cloudflare during {@code refreshConfiguration}: the zone itself
 * and every custom certificate uploaded to it. Each certificate is a discoverable asset a customer
 * can select in TLM; selecting one drives the "replace this certificate" flow.
 */
@Data
public class CloudflareConfigurationData {

    /** Marks the endpoint OS name in the TLM inventory. */
    public static final String OS_NAME = "CLOUDFLARE";

    private CloudflareZone zone;

    private List<CloudflareCertificate> certificates = new ArrayList<>();
}
