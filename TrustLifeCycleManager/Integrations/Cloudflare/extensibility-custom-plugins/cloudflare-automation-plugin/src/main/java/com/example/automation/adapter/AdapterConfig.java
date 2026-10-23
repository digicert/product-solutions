package com.example.automation.adapter;

import java.util.Locale;

import lombok.Builder;
import lombok.Data;

/**
 * Settings for one Cloudflare zone, built from the TLM connector configuration.
 *
 * <p>The Cloudflare API ({@code https://api.cloudflare.com/client/v4}) authenticates every request
 * with {@code Authorization: Bearer <API token>}. The token needs <em>Zone → SSL and Certificates →
 * Edit</em> (custom certificates and custom CSRs) and <em>Zone → Zone → Read</em> on the zone.
 */
@Data
@Builder
public class AdapterConfig {

    public static final String DEFAULT_API_BASE_URL = "https://api.cloudflare.com/client/v4";

    public static final String CSR_MODE_CLOUDFLARE = "cloudflare";
    public static final String CSR_MODE_SENSOR = "sensor";

    public static final String STRATEGY_UPDATE = "update";
    public static final String STRATEGY_REPLACE_DELETE = "replace_delete";
    public static final String STRATEGY_REPLACE_KEEP = "replace_keep";

    public static final String TYPE_SNI_CUSTOM = "sni_custom";
    public static final String TYPE_LEGACY_CUSTOM = "legacy_custom";

    public static final String BUNDLE_FORCE = "force";
    public static final String BUNDLE_UBIQUITOUS = "ubiquitous";
    public static final String BUNDLE_OPTIMAL = "optimal";

    public static final int DEFAULT_CSR_RETENTION = 5;

    /** Default wall-clock budget for TLS probes that fetch certificate bodies during discovery. */
    public static final long DEFAULT_PROBE_BUDGET_MILLIS = 20_000L;

    /** Base URL of the Cloudflare API; overridable for tests. */
    private String apiBaseUrl;

    /** Cloudflare zone id (32 hex characters). */
    private String zoneId;

    /** API token, sent as {@code Authorization: Bearer}. Never logged. */
    private String apiToken;

    /** {@link #CSR_MODE_CLOUDFLARE} (default) or {@link #CSR_MODE_SENSOR}. */
    private String csrMode;

    /** {@code C=…, ST=…, L=…, O=…} filling attributes Cloudflare CSRs require when the TLM DN lacks them. */
    private String csrSubjectFallback;

    /** {@link #STRATEGY_UPDATE} (default), {@link #STRATEGY_REPLACE_DELETE} or {@link #STRATEGY_REPLACE_KEEP}. */
    private String renewalStrategy;

    /** {@link #TYPE_SNI_CUSTOM} (default) or {@link #TYPE_LEGACY_CUSTOM} for new uploads. */
    private String certificateType;

    /** {@link #BUNDLE_FORCE} (default), {@link #BUNDLE_UBIQUITOUS} or {@link #BUNDLE_OPTIMAL}. */
    private String bundleMethod;

    /** Older Cloudflare CSRs per common name to keep after a successful install. */
    private int csrRetention;

    /** Time budget for certificate-body probes during discovery / thumbprint matching. */
    private long probeBudgetMillis;

    public String effectiveApiBaseUrl() {
        var base = apiBaseUrl == null || apiBaseUrl.isBlank() ? DEFAULT_API_BASE_URL : apiBaseUrl.trim();
        while (base.endsWith("/")) {
            base = base.substring(0, base.length() - 1);
        }
        return base;
    }

    public boolean isCloudflareCsr() {
        return csrMode == null || csrMode.isBlank() || CSR_MODE_CLOUDFLARE.equalsIgnoreCase(csrMode.trim());
    }

    public String effectiveStrategy() {
        if (renewalStrategy == null || renewalStrategy.isBlank()) {
            return STRATEGY_UPDATE;
        }
        return renewalStrategy.trim().toLowerCase(Locale.ROOT);
    }

    public boolean isUpdateStrategy() {
        return STRATEGY_UPDATE.equals(effectiveStrategy());
    }

    public boolean isKeepReplaced() {
        return STRATEGY_REPLACE_KEEP.equals(effectiveStrategy());
    }

    public String effectiveCertificateType() {
        return certificateType == null || certificateType.isBlank()
                ? TYPE_SNI_CUSTOM : certificateType.trim().toLowerCase(Locale.ROOT);
    }

    public String effectiveBundleMethod() {
        return bundleMethod == null || bundleMethod.isBlank()
                ? BUNDLE_FORCE : bundleMethod.trim().toLowerCase(Locale.ROOT);
    }

    public long effectiveProbeBudgetMillis() {
        return probeBudgetMillis < 0 ? 0 : probeBudgetMillis;
    }

    /** {@code /zones/<id>} — prefix of every zone-scoped call. */
    public String zonePath() {
        return "/zones/" + CloudflareRestClient.urlEncode(zoneId);
    }

    /** Trims whitespace and a copied {@code Zone ID:} label; returns null when empty. */
    public static String normalizeZoneId(String raw) {
        if (raw == null) {
            return null;
        }
        var id = raw.trim();
        final int colon = id.lastIndexOf(':');
        if (colon >= 0) {
            id = id.substring(colon + 1).trim();
        }
        return id.isBlank() ? null : id;
    }

    /** True when the id looks like a Cloudflare zone id (32 hex characters). */
    public static boolean looksLikeZoneId(String id) {
        return id != null && id.matches("[0-9a-fA-F]{32}");
    }
}
