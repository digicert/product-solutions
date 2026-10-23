package com.example.automation.model;

import java.util.ArrayList;
import java.util.List;

import lombok.Data;

/**
 * Outcome of a successful {@code installCertificate}: the Cloudflare custom certificate id that
 * now carries the renewed certificate, and a summary of what happened to the previous one(s) —
 * custom certificates as well as Cloudflare-managed certificate packs that were handed over.
 */
@Data
public class CloudflareInstalledCertificate {

    /** Id of the custom certificate carrying the new certificate (same as before in update mode). */
    private String certificateId;

    /** Upper-case hex serial of the uploaded end-entity certificate. */
    private String serialNumber;

    /** Cloudflare status at the end of the install ({@code active}, {@code pending}, …). */
    private String status;

    /** Serial the Cloudflare edge served for the certificate's hosts right after the install (best effort), or null. */
    private String servedSerialNumber;

    /** {@code update} (PATCHed in place), {@code upload} (new certificate created) or {@code existing} (already there). */
    private String action;

    /** Ids of the previous custom certificates that were deleted after the upload. */
    private List<String> deletedCertificates = new ArrayList<>();

    /** Ids of the previous custom certificates intentionally left in place (kept or delete failed). */
    private List<String> retainedCertificates = new ArrayList<>();

    /** Number of older Cloudflare CSR records removed by the retention clean-up. */
    private int csrsDeleted;

    // ---- Cloudflare-managed certificates (Universal SSL / Advanced Certificate Manager) ----

    /** Managed ids ({@code pack-<id>}) retired after the install: Universal SSL disabled or the pack deleted. */
    private List<String> retiredManaged = new ArrayList<>();

    /** Managed ids left in place (connector keeps them, hostnames not fully covered, or the API call failed). */
    private List<String> retainedManaged = new ArrayList<>();

    /** Managed ids whose retirement waits for the custom certificate to become active (retried by validateCertificate). */
    private List<String> pendingManagedRetirements = new ArrayList<>();

    /** True when this install turned Universal SSL off for the zone. */
    private boolean universalSslDisabled;

    public boolean isActive() {
        return status != null && "active".equalsIgnoreCase(status.trim());
    }
}
