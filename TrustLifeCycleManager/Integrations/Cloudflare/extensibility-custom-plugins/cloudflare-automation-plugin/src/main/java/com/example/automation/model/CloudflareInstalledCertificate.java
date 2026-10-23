package com.example.automation.model;

import java.util.ArrayList;
import java.util.List;

import lombok.Data;

/**
 * Outcome of a successful {@code installCertificate}: the Cloudflare custom certificate id that
 * now carries the renewed certificate, and a summary of what happened to the previous one(s).
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
}
