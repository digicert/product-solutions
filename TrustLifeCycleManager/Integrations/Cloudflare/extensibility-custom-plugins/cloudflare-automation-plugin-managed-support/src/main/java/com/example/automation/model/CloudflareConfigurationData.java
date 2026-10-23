package com.example.automation.model;

import java.util.ArrayList;
import java.util.List;

import lombok.Data;

/**
 * Aggregated inventory pulled from Cloudflare during {@code refreshConfiguration}: the zone itself,
 * every custom certificate uploaded to it and — unless the connector is set to ignore them — the
 * Cloudflare-managed certificate packs (Universal SSL, Advanced Certificate Manager, Total TLS).
 * Each certificate is a discoverable asset a customer can select in TLM; selecting one drives the
 * "replace this certificate" flow. Selecting a managed one drives the "switch this hostname from the
 * Cloudflare-issued certificate to a custom (DigiCert) certificate" flow.
 */
@Data
public class CloudflareConfigurationData {

    /** Marks the endpoint OS name in the TLM inventory. */
    public static final String OS_NAME = "CLOUDFLARE";

    private CloudflareZone zone;

    /** Custom certificates uploaded to the zone. */
    private List<CloudflareCertificate> certificates = new ArrayList<>();

    /** Cloudflare-managed certificate packs surfaced as assets (empty when ignored by configuration). */
    private List<CloudflareCertificate> managedCertificates = new ArrayList<>();

    /** Universal SSL setting of the zone when it could be read. */
    private Boolean universalSslEnabled;

    /** Total TLS setting of the zone when it could be read (Advanced Certificate Manager feature). */
    private Boolean totalTlsEnabled;

    /** Custom certificates first, then the managed ones — the order discovery reports them in. */
    public List<CloudflareCertificate> allCertificates() {
        final List<CloudflareCertificate> all = new ArrayList<>(certificates == null ? List.of() : certificates);
        if (managedCertificates != null) {
            all.addAll(managedCertificates);
        }
        return all;
    }
}
