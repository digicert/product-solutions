package com.example.automation.adapter;

import java.io.IOException;
import java.net.InetSocketAddress;
import java.net.Socket;
import java.security.SecureRandom;
import java.security.cert.Certificate;
import java.security.cert.X509Certificate;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Objects;
import java.util.Optional;
import java.util.Set;

import javax.net.ssl.SNIHostName;
import javax.net.ssl.SSLContext;
import javax.net.ssl.SSLSocket;
import javax.net.ssl.TrustManager;
import javax.net.ssl.X509TrustManager;

import com.example.automation.helper.CertificateAttributesUtil;
import com.example.automation.helper.CloudflareAutomationPluginHelper;
import com.example.automation.model.CloudflareCertificate;
import com.example.automation.model.CloudflareConfigurationData;
import com.example.automation.model.CloudflareGeneratedCsr;
import com.example.automation.model.CloudflareInstalledCertificate;
import com.example.automation.model.CloudflareZone;
import com.example.automation.model.Connection;
import com.example.automation.model.ErrorCode;
import com.example.automation.model.Result;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.node.ArrayNode;
import com.fasterxml.jackson.databind.node.ObjectNode;

import lombok.extern.slf4j.Slf4j;

/**
 * Drives all certificate-lifecycle operations against one Cloudflare zone over the Cloudflare v4
 * API. The endpoints and the rotation strategy follow the DigiCert post-enrollment scripts
 * ({@code csr-in-cloudflare-api.sh}, {@code csr_in_digicert_awr.sh}):
 *
 * <pre>
 *   GET    /user/tokens/verify                                     token status (testConnection)
 *   GET    /zones/{zone}                                           zone name / status / plan
 *   GET    /zones/{zone}/custom_certificates?page=N&per_page=50    inventory (metadata only, no PEM)
 *   GET    /zones/{zone}/custom_certificates/{id}                  one certificate (status polling, validate)
 *   POST   /zones/{zone}/custom_csrs                               Cloudflare-side key pair + CSR
 *   GET/DELETE /zones/{zone}/custom_csrs[/{id}]                    CSR retention clean-up
 *   POST   /zones/{zone}/custom_certificates                       upload a new certificate
 *   PATCH  /zones/{zone}/custom_certificates/{id}                  replace the certificate in place
 *   DELETE /zones/{zone}/custom_certificates/{id}                  remove a replaced certificate
 * </pre>
 *
 * <p><b>Certificate bodies.</b> Cloudflare never returns the PEM of a custom certificate. TLM only
 * inventories a certificate it has the body of, so discovery performs a TLS handshake against the
 * Cloudflare edge for the certificate's hostnames and accepts the served certificate when its
 * {@code notAfter} equals Cloudflare's {@code expires_on} and its names overlap the listed hosts.
 */
@Slf4j
public class CloudflareAdapter {

    static final String PATH_TOKEN_VERIFY = "/user/tokens/verify";
    static final String CUSTOM_CERTIFICATES = "/custom_certificates";
    static final String CUSTOM_CSRS = "/custom_csrs";

    private static final int PAGE_SIZE = 50;
    private static final int MAX_PAGES = 40;
    private static final long ACTIVE_WAIT_MILLIS = 12_000L;
    private static final long ACTIVE_POLL_MILLIS = 2_000L;
    private static final int TLS_TIMEOUT_MILLIS = 5_000;
    private static final int MAX_PROBE_CANDIDATES = 8;

    private static final ObjectMapper MAPPER = new ObjectMapper();

    private final CloudflareRestClient client;
    private final AdapterConfig config;

    public CloudflareAdapter(AdapterConfig config) {
        this.config = config;
        this.client = new CloudflareRestClient(config);
    }

    // ------------------------------------------------------------------ testConnection

    public Result<Connection> testConnection() {
        try {
            // 1. token: /user/tokens/verify answers for any API token
            final var verify = client.get(PATH_TOKEN_VERIFY);
            if (verify.statusCode() == 401 || verify.statusCode() == 403) {
                return Result.failure("Cloudflare rejected the API token (" + CloudflareRestClient.describeFailure(verify)
                        + "). Check that the token is complete and not expired or disabled.", ErrorCode.UNAUTHORIZED.name());
            }
            if (CloudflareRestClient.isCloudflareSuccess(verify)) {
                final var status = CloudflareRestClient.result(verify).path("status").asText("");
                if (!status.isBlank() && !"active".equalsIgnoreCase(status)) {
                    return Result.failure("The Cloudflare API token status is '" + status + "' (expected 'active').",
                            ErrorCode.UNAUTHORIZED.name());
                }
                log.info("API token verified: id={}, status={}", CloudflareRestClient.result(verify).path("id").asText("?"), status);
            } else {
                log.warn("Token verification endpoint did not confirm the token ({}); continuing with the zone check",
                        CloudflareRestClient.describeFailure(verify));
            }
            // 2. zone readable, 3. custom certificates listable (= SSL and Certificates permission)
            final var zone = getZone();
            final var certs = listCertificates();
            log.info("testConnection OK: zone '{}' ({}, status={}, plan={}) with {} custom certificate(s)",
                    zone.getName(), zone.getId(), zone.getStatus(), zone.getPlanName(), certs.size());
            return Result.success(new Connection(true));
        } catch (CloudflareApiException e) {
            log.error("Error during testConnection", e);
            return Result.failure(e.getMessage(), e.isUnauthorized() ? ErrorCode.UNAUTHORIZED.name()
                    : ErrorCode.CLOUDFLARE_API_ERROR.name());
        } catch (Exception e) {
            log.error("Error during testConnection", e);
            return Result.failure(describe(e), ErrorCode.INTERNAL_ERROR.name());
        }
    }

    // ------------------------------------------------------------------ zone

    public CloudflareZone getZone() throws IOException, InterruptedException {
        final var response = client.get(config.zonePath());
        if (!CloudflareRestClient.isCloudflareSuccess(response)) {
            throw new CloudflareApiException("Cannot read Cloudflare zone '" + config.getZoneId() + "': "
                    + CloudflareRestClient.describeFailure(response)
                    + (response.statusCode() == 403 || response.statusCode() == 401
                            ? ". The token needs Zone > Zone > Read on this zone, and the zone id must belong to an account the token can access."
                            : response.statusCode() == 404 ? ". Check the Zone ID (zone Overview > API section in the Cloudflare dashboard)." : ""),
                    response.statusCode());
        }
        final var n = CloudflareRestClient.result(response);
        final var zone = new CloudflareZone();
        zone.setId(n.path("id").asText(config.getZoneId()));
        zone.setName(n.path("name").asText(null));
        zone.setStatus(n.path("status").asText(null));
        zone.setType(n.path("type").asText(null));
        zone.setPaused(n.path("paused").isBoolean() ? n.path("paused").asBoolean() : null);
        zone.setAccountId(n.path("account").path("id").asText(null));
        zone.setAccountName(n.path("account").path("name").asText(null));
        zone.setPlanName(n.path("plan").path("name").asText(null));
        return zone;
    }

    // ------------------------------------------------------------------ certificate list

    /** Every custom certificate of the zone except those Cloudflare reports as {@code deleted}. */
    public List<CloudflareCertificate> listCertificates() throws IOException, InterruptedException {
        final List<CloudflareCertificate> certs = new ArrayList<>();
        for (int page = 1; page <= MAX_PAGES; page++) {
            final var path = CloudflareRestClient.withQuery(config.zonePath() + CUSTOM_CERTIFICATES,
                    "page=" + page + "&per_page=" + PAGE_SIZE);
            final var response = client.get(path);
            if (!CloudflareRestClient.isCloudflareSuccess(response)) {
                throw new CloudflareApiException("Listing custom certificates of zone '" + config.getZoneId() + "' failed: "
                        + CloudflareRestClient.describeFailure(response)
                        + (response.statusCode() == 403 ? ". The token needs Zone > SSL and Certificates > Edit." : ""),
                        response.statusCode());
            }
            final var root = CloudflareRestClient.json(response.body());
            int seen = 0;
            for (JsonNode n : root.path("result")) {
                final var c = parseCertificate(n);
                seen++;
                if (c.getId() == null || c.isDeleted()) {
                    continue;
                }
                certs.add(c);
            }
            final var totalPages = root.path("result_info").path("total_pages").asInt(1);
            if (seen == 0 || page >= totalPages) {
                break;
            }
        }
        return certs;
    }

    static CloudflareCertificate parseCertificate(JsonNode n) {
        final var c = new CloudflareCertificate();
        c.setId(n.path("id").asText(null));
        c.setZoneId(n.path("zone_id").asText(null));
        final List<String> hosts = new ArrayList<>();
        for (JsonNode h : n.path("hosts")) {
            if (h.isTextual() && !h.asText().isBlank()) {
                hosts.add(h.asText().trim());
            }
        }
        c.setHosts(hosts);
        c.setIssuer(n.path("issuer").asText(null));
        c.setSignature(n.path("signature").asText(null));
        c.setStatus(n.path("status").asText(null));
        c.setBundleMethod(n.path("bundle_method").asText(null));
        c.setType(n.path("type").asText(null));
        c.setPriority(n.path("priority").isNumber() ? n.path("priority").asInt() : null);
        c.setCustomCsrId(n.path("custom_csr_id").asText(null));
        c.setExpiresOn(n.path("expires_on").asText(null));
        c.setExpiresOnEpoch(CloudflareAutomationPluginHelper.parseEpochSeconds(c.getExpiresOn()));
        c.setUploadedOn(n.path("uploaded_on").asText(null));
        c.setModifiedOn(n.path("modified_on").asText(null));
        return c;
    }

    /** One custom certificate by id; empty when Cloudflare answers 404 / "not found". */
    public Optional<CloudflareCertificate> getCertificate(String id) throws IOException, InterruptedException {
        final var response = client.get(config.zonePath() + CUSTOM_CERTIFICATES + "/" + CloudflareRestClient.urlEncode(id));
        if (response.statusCode() == 404) {
            return Optional.empty();
        }
        if (!CloudflareRestClient.isCloudflareSuccess(response)) {
            // Seen live (2026-10-12): an unknown id answers HTTP 400 "code 1002: Invalid certificate",
            // not 404. Treat that, "not found" wording and code 1000 as "not present".
            final var msg = CloudflareRestClient.errorMessage(response.body());
            if ((msg != null && msg.toLowerCase(Locale.ROOT).contains("not found"))
                    || CloudflareRestClient.hasErrorCode(response, 1002)
                    || CloudflareRestClient.hasErrorCode(response, 1000)) {
                return Optional.empty();
            }
            throw new CloudflareApiException("Reading custom certificate '" + id + "' failed: "
                    + CloudflareRestClient.describeFailure(response), response.statusCode());
        }
        final var c = parseCertificate(CloudflareRestClient.result(response));
        return c.getId() == null || c.isDeleted() ? Optional.empty() : Optional.of(c);
    }

    // ------------------------------------------------------------------ refreshConfiguration

    /**
     * Builds the inventory: the zone plus every custom certificate, each with its body when it
     * could be fetched from the edge within the probe budget. Expired and pending certificates
     * are surfaced too — they are exactly what an operator wants to replace.
     */
    public Result<CloudflareConfigurationData> getConfigurationData() {
        try {
            final var data = new CloudflareConfigurationData();
            final var zone = getZone();
            data.setZone(zone);
            final var certs = listCertificates();
            final long deadline = System.currentTimeMillis() + config.effectiveProbeBudgetMillis();
            for (CloudflareCertificate cert : certs) {
                cert.setCertificatePem(tryFetchCertificatePem(cert, zone.getName(), deadline));
                applyPem(cert);
                log.info("Discovered custom certificate: id={}, hosts={}, issuer={}, signature={}, status={}, type={}, bundle={}, "
                        + "priority={}, expires={}, csr={}, pem={}",
                        cert.getId(), cert.getHosts(), cert.getIssuer(), cert.getSignature(), cert.getStatus(), cert.getType(),
                        cert.getBundleMethod(), cert.getPriority(), cert.getExpiresOn(), cert.getCustomCsrId(),
                        cert.getCertificatePem() != null ? "yes" : "no");
            }
            data.setCertificates(certs);
            log.info("RefreshConfiguration discovered {} custom certificate(s) in zone '{}' ({})", certs.size(),
                    zone.getName(), zone.getId());
            return Result.success(data);
        } catch (CloudflareApiException e) {
            log.error("Error during getConfigurationData", e);
            return Result.failure(e.getMessage(), e.isUnauthorized() ? ErrorCode.UNAUTHORIZED.name()
                    : ErrorCode.CLOUDFLARE_API_ERROR.name());
        } catch (Exception e) {
            log.error("Error during getConfigurationData", e);
            return Result.failure(describe(e), ErrorCode.CLOUDFLARE_API_ERROR.name());
        }
    }

    // ------------------------------------------------------------------ certificate bodies (best effort)

    /** Id → PEM for every certificate whose body can be fetched from the edge within the probe budget. */
    public Map<String, String> knownCertificatePems(List<CloudflareCertificate> certs, String zoneName) {
        final Map<String, String> pems = new LinkedHashMap<>();
        final long deadline = System.currentTimeMillis() + config.effectiveProbeBudgetMillis();
        for (CloudflareCertificate c : certs) {
            if (c.getCertificatePem() == null) {
                c.setCertificatePem(tryFetchCertificatePem(c, zoneName, deadline));
                applyPem(c);
            }
            if (c.getCertificatePem() != null) {
                pems.put(c.getId(), c.getCertificatePem());
            }
        }
        return pems;
    }

    /**
     * Performs TLS handshakes against the Cloudflare edge for the certificate's hostnames and
     * returns the served certificate as PEM when it is this one ({@code notAfter} equals
     * {@code expires_on} and the names overlap). Candidates, in order: each non-wildcard host
     * directly; the same hosts via the zone apex address (for DNS-only records); for wildcard hosts
     * {@code www.<base>} and the base. Returns null when nothing matches before {@code deadline}.
     */
    public String tryFetchCertificatePem(CloudflareCertificate cert, String zoneName, long deadline) {
        if (cert.getCertificatePem() != null) {
            return cert.getCertificatePem();
        }
        if (config.effectiveProbeBudgetMillis() <= 0) {
            log.info("Certificate body probing is disabled (probe budget 0) - surfacing metadata only for '{}'", cert.getId());
            return null;
        }
        if (!cert.isActive()) {
            // Only an active certificate is served by the edge; probing would return another one.
            log.info("Certificate '{}' has status '{}' - the edge does not serve it, no body available",
                    cert.getId(), cert.getStatus());
            return null;
        }
        final var candidates = probeCandidates(cert, zoneName);
        for (String[] candidate : candidates) {
            if (System.currentTimeMillis() >= deadline) {
                log.warn("Probe budget exhausted before the body of certificate '{}' could be fetched - surfacing metadata only",
                        cert.getId());
                return null;
            }
            final var connectHost = candidate[0];
            final var sni = candidate[1];
            try {
                final var served = fetchLeafViaTls(connectHost, 443, sni, TLS_TIMEOUT_MILLIS);
                if (served == null) {
                    continue;
                }
                if (servedMatches(cert, served)) {
                    log.info("Certificate body for '{}' fetched via TLS from {} (SNI {})", cert.getId(), connectHost, sni);
                    return CloudflareAutomationPluginHelper.toPem("CERTIFICATE", served.getEncoded());
                }
                log.info("TLS to {} (SNI {}) served a different certificate (notAfter {}, names {}) than '{}' (expires {}, hosts {})",
                        connectHost, sni, served.getNotAfter().toInstant(), CertificateAttributesUtil.coveredNames(served),
                        cert.getId(), cert.getExpiresOn(), cert.getHosts());
            } catch (Exception e) {
                log.debug("TLS probe {} (SNI {}) failed: {}", connectHost, sni, e.getMessage());
            }
        }
        log.info("Certificate body for '{}' is not retrievable from the Cloudflare edge - surfacing metadata only", cert.getId());
        return null;
    }

    /** Ordered, de-duplicated {@code {connectHost, sni}} pairs to try for a certificate. */
    public static List<String[]> probeCandidates(CloudflareCertificate cert, String zoneName) {
        final Set<String> seen = new LinkedHashSet<>();
        final List<String[]> result = new ArrayList<>();
        final List<String> plain = cert.nonWildcardHosts();
        // the primary host first, then the rest
        final var primary = cert.primaryHost();
        if (primary != null && plain.contains(primary)) {
            plain.remove(primary);
            plain.add(0, primary);
        }
        for (String h : plain) {
            add(result, seen, h, h);
        }
        if (zoneName != null && !zoneName.isBlank()) {
            for (String h : plain) {
                add(result, seen, zoneName, h);
            }
        }
        for (String w : cert.wildcardHosts()) {
            final var base = w.substring(2);
            final var www = "www." + base;
            add(result, seen, www, www);
            if (zoneName != null && !zoneName.isBlank()) {
                add(result, seen, zoneName, www);
                add(result, seen, zoneName, base);
            }
            add(result, seen, base, base);
        }
        return result.size() > MAX_PROBE_CANDIDATES ? new ArrayList<>(result.subList(0, MAX_PROBE_CANDIDATES)) : result;
    }

    private static void add(List<String[]> result, Set<String> seen, String connectHost, String sni) {
        if (connectHost == null || sni == null || connectHost.isBlank() || sni.isBlank()) {
            return;
        }
        if (seen.add(connectHost + "|" + sni)) {
            result.add(new String[] { connectHost, sni });
        }
    }

    /** The served certificate is the listed one when the expiry agrees and at least one name overlaps. */
    public static boolean servedMatches(CloudflareCertificate cert, X509Certificate served) {
        final long notAfter = served.getNotAfter().toInstant().getEpochSecond();
        if (cert.getExpiresOnEpoch() != null && Math.abs(cert.getExpiresOnEpoch() - notAfter) > 1) {
            return false;
        }
        if (cert.getHosts() == null || cert.getHosts().isEmpty()) {
            return cert.getExpiresOnEpoch() != null;
        }
        final var names = CertificateAttributesUtil.coveredNames(served);
        for (String h : cert.getHosts()) {
            final var lower = h.toLowerCase(Locale.ROOT);
            if (names.contains(lower)) {
                return true;
            }
            for (String n : names) {
                if (CertificateAttributesUtil.hostMatches(n, lower) || CertificateAttributesUtil.hostMatches(lower, n)) {
                    return true;
                }
            }
        }
        return false;
    }

    /** When the PEM is known, the X.509 fields parsed from it take precedence over Cloudflare's summary. */
    public static void applyPem(CloudflareCertificate c) {
        if (c.getCertificatePem() == null) {
            return;
        }
        try {
            final var x = CloudflareAutomationPluginHelper.parseFirstCertificate(c.getCertificatePem());
            c.setSubject(x.getSubjectX500Principal().getName());
            c.setIssuerDn(x.getIssuerX500Principal().getName());
            c.setCommonName(CertificateAttributesUtil.getCommonName(x.getSubjectX500Principal().getName()));
            c.setSerialNumber(CertificateAttributesUtil.serialHex(x));
            c.setValidFrom(x.getNotBefore().toInstant().toString());
            c.setValidTo(x.getNotAfter().toInstant().toString());
            if (c.getExpiresOnEpoch() == null) {
                c.setExpiresOnEpoch(x.getNotAfter().toInstant().getEpochSecond());
            }
            c.setKeyType(CertificateAttributesUtil.keyTypeOf(x));
            c.setKeySize(CertificateAttributesUtil.keySizeOf(x));
            c.setFingerprintSha256(CertificateAttributesUtil.fingerprintHex(x, "SHA-256"));
        } catch (Exception e) {
            log.warn("Certificate '{}' carries a body that does not parse as X.509 ({}) - ignoring it", c.getId(), e.getMessage());
            c.setCertificatePem(null);
        }
    }

    /** Opens a trust-all TLS connection with SNI and returns the served leaf certificate. */
    static X509Certificate fetchLeafViaTls(String host, int port, String sni, int timeoutMillis) throws Exception {
        final var ctx = SSLContext.getInstance("TLS");
        ctx.init(null, new TrustManager[] { new X509TrustManager() {
            @Override public void checkClientTrusted(X509Certificate[] c, String a) { }
            @Override public void checkServerTrusted(X509Certificate[] c, String a) { }
            @Override public X509Certificate[] getAcceptedIssuers() { return new X509Certificate[0]; }
        } }, new SecureRandom());
        try (Socket plain = new Socket()) {
            plain.connect(new InetSocketAddress(host, port), timeoutMillis);
            try (SSLSocket socket = (SSLSocket) ctx.getSocketFactory().createSocket(plain, sni, port, true)) {
                socket.setSoTimeout(timeoutMillis);
                if (sni != null && !sni.isBlank() && !sni.startsWith("*")) {
                    final var params = socket.getSSLParameters();
                    params.setServerNames(List.of(new SNIHostName(sni)));
                    socket.setSSLParameters(params);
                }
                socket.startHandshake();
                final Certificate[] chain = socket.getSession().getPeerCertificates();
                return chain.length > 0 && chain[0] instanceof X509Certificate x ? x : null;
            }
        }
    }

    // ------------------------------------------------------------------ CSR (Cloudflare key mode)

    /**
     * Creates a Cloudflare custom CSR: Cloudflare generates the key pair, keeps the private key and
     * returns the PEM CSR plus the id that the certificate upload references.
     */
    public Result<CloudflareGeneratedCsr> createCsr(String subjectDn, List<String> dnsNames, String keyAlgorithm,
                                                    String keySize) {
        try {
            final var dn = CertificateAttributesUtil.parseDn(subjectDn);
            var cn = dn.get("CN");
            if ((cn == null || cn.isBlank()) && dnsNames != null && !dnsNames.isEmpty()) {
                cn = dnsNames.get(0);
            }
            if (cn == null || cn.isBlank()) {
                return Result.failure("A common name (subject CN or at least one DNS name) is required to create a Cloudflare CSR",
                        ErrorCode.CSR_GENERATION_ERROR.name());
            }
            cn = cn.trim();
            if (cn.length() > 64) {
                return Result.failure("Common name '" + cn + "' exceeds Cloudflare's 64-character limit for custom CSRs",
                        ErrorCode.CSR_GENERATION_ERROR.name());
            }
            final Set<String> sans = new LinkedHashSet<>();
            sans.add(cn);
            if (dnsNames != null) {
                dnsNames.stream().filter(s -> s != null && !s.isBlank()).map(String::trim).forEach(sans::add);
            }
            final var fallback = CertificateAttributesUtil.parseDn(config.getCsrSubjectFallback());
            final var country = firstNonBlank(dn.get("C"), fallback.get("C"));
            final var state = firstNonBlank(dn.get("ST"), dn.get("S"), fallback.get("ST"), fallback.get("S"));
            final var locality = firstNonBlank(dn.get("L"), fallback.get("L"));
            final var organization = firstNonBlank(dn.get("O"), fallback.get("O"));
            final var ou = firstNonBlank(dn.get("OU"), fallback.get("OU"));
            final List<String> missing = new ArrayList<>();
            if (country == null) { missing.add("C"); }
            if (state == null) { missing.add("ST"); }
            if (locality == null) { missing.add("L"); }
            if (organization == null) { missing.add("O"); }
            if (!missing.isEmpty()) {
                return Result.failure("Cloudflare custom CSRs require country, state, locality and organization; missing "
                        + missing + " in the subject DN [" + subjectDn + "] and in the connector's CSR subject fallback ["
                        + config.getCsrSubjectFallback() + "]", ErrorCode.CSR_GENERATION_ERROR.name());
            }
            if (country.length() != 2) {
                return Result.failure("Country '" + country + "' must be a two-letter ISO 3166-1 code for a Cloudflare CSR",
                        ErrorCode.CSR_GENERATION_ERROR.name());
            }
            final var keyType = mapKeyType(keyAlgorithm, keySize);

            final ObjectNode payload = MAPPER.createObjectNode();
            payload.put("common_name", cn);
            payload.put("country", country.toUpperCase(Locale.ROOT));
            payload.put("state", state);
            payload.put("locality", locality);
            payload.put("organization", organization);
            if (ou != null) {
                payload.put("organizational_unit", ou);
            }
            payload.put("key_type", keyType);
            final ArrayNode sanNode = payload.putArray("sans");
            sans.forEach(sanNode::add);
            log.info("Creating Cloudflare CSR: cn={}, sans={}, key_type={}, C={}, ST={}, L={}, O={}", cn, sans, keyType,
                    country, state, locality, organization);

            final var response = client.postJson(config.zonePath() + CUSTOM_CSRS, MAPPER.writeValueAsString(payload));
            if (!CloudflareRestClient.isCloudflareSuccess(response)) {
                return Result.failure("Cloudflare refused to create the CSR: " + CloudflareRestClient.describeFailure(response),
                        ErrorCode.CSR_GENERATION_ERROR.name());
            }
            final var result = CloudflareRestClient.result(response);
            final var id = result.path("id").asText(null);
            final var csr = result.path("csr").asText(null);
            if (id == null || csr == null || !csr.contains("-----BEGIN")) {
                return Result.failure("Cloudflare created a CSR but the response carries no id/csr: "
                        + CloudflareRestClient.describeFailure(response), ErrorCode.CSR_GENERATION_ERROR.name());
            }
            final var generated = new CloudflareGeneratedCsr();
            generated.setCsr(CloudflareAutomationPluginHelper.normalizePem(csr.replace("\\n", "\n")));
            generated.setCustomCsrId(id);
            generated.setCommonName(cn);
            generated.setKeyType(keyType);
            log.info("Cloudflare CSR created: id={}, key_type={}", id, result.path("key_type").asText(keyType));
            return Result.success(generated);
        } catch (Exception e) {
            log.error("Error during createCsr", e);
            return Result.failure(describe(e), ErrorCode.CSR_GENERATION_ERROR.name());
        }
    }

    /**
     * Cloudflare custom CSRs support {@code rsa2048} and {@code p256v1} only. Other sizes are
     * mapped to the nearest supported type with a warning; the CA enforces the profile's key
     * policy at enrollment time.
     */
    public static String mapKeyType(String keyAlgorithm, String keySize) {
        final var alg = keyAlgorithm == null ? "" : keyAlgorithm.trim().toLowerCase(Locale.ROOT);
        final int bits = CloudflareAutomationPluginHelper.parseIntOrDefault(keySize, 0);
        if (alg.startsWith("ec")) {
            if (bits != 0 && bits != 256) {
                log.warn("TLM asked for an EC {}-bit key but Cloudflare CSRs only support P-256 - using p256v1", bits);
            }
            return "p256v1";
        }
        if (bits != 0 && bits != 2048) {
            log.warn("TLM asked for an RSA {}-bit key but Cloudflare CSRs only support RSA 2048 - using rsa2048. "
                    + "Use the 'sensor' CSR mode for other key sizes.", bits);
        }
        return "rsa2048";
    }

    public List<JsonNode> listCsrs() throws IOException, InterruptedException {
        final List<JsonNode> csrs = new ArrayList<>();
        for (int page = 1; page <= MAX_PAGES; page++) {
            final var response = client.get(CloudflareRestClient.withQuery(config.zonePath() + CUSTOM_CSRS,
                    "page=" + page + "&per_page=" + PAGE_SIZE));
            if (!CloudflareRestClient.isCloudflareSuccess(response)) {
                throw new CloudflareApiException("Listing custom CSRs failed: " + CloudflareRestClient.describeFailure(response),
                        response.statusCode());
            }
            final var root = CloudflareRestClient.json(response.body());
            int seen = 0;
            for (JsonNode n : root.path("result")) {
                csrs.add(n);
                seen++;
            }
            if (seen == 0 || page >= root.path("result_info").path("total_pages").asInt(1)) {
                break;
            }
        }
        return csrs;
    }

    public boolean deleteCsr(String id) {
        try {
            final var response = client.delete(config.zonePath() + CUSTOM_CSRS + "/" + CloudflareRestClient.urlEncode(id));
            if (CloudflareRestClient.isCloudflareSuccess(response)) {
                return true;
            }
            log.warn("Could not delete CSR '{}': {}", id, CloudflareRestClient.describeFailure(response));
            return false;
        } catch (Exception e) {
            log.warn("Could not delete CSR '{}': {}", id, describe(e));
            return false;
        }
    }

    /**
     * Deletes older Cloudflare CSR records for {@code commonName}, keeping the {@code retention}
     * most recent ones and always {@code keepId}. Never throws; returns the number deleted.
     */
    public int cleanupCsrs(String commonName, String keepId, int retention) {
        if (commonName == null || commonName.isBlank()) {
            return 0;
        }
        try {
            final List<JsonNode> same = new ArrayList<>();
            for (JsonNode n : listCsrs()) {
                if (commonName.equalsIgnoreCase(n.path("common_name").asText("")) && !n.path("id").asText("").equals(keepId)) {
                    same.add(n);
                }
            }
            same.sort((a, b) -> a.path("created_at").asText("").compareTo(b.path("created_at").asText("")));
            final int toDelete = Math.max(0, same.size() - Math.max(0, retention));
            log.info("CSR clean-up for '{}': {} older CSR(s), retention {}, deleting {}", commonName, same.size(), retention, toDelete);
            int deleted = 0;
            for (int i = 0; i < toDelete; i++) {
                final var id = same.get(i).path("id").asText();
                if (deleteCsr(id)) {
                    deleted++;
                    log.info("Deleted old CSR '{}' (created {})", id, same.get(i).path("created_at").asText(""));
                }
            }
            return deleted;
        } catch (Exception e) {
            log.warn("CSR clean-up skipped: {}", describe(e));
            return 0;
        }
    }

    // ------------------------------------------------------------------ installCertificate

    /**
     * Puts the renewed certificate into the zone and retires the previous one(s):
     * <ul>
     *   <li><b>update</b> (default): {@code PATCH} the first id of {@code replacedIds}. Cloudflare
     *       answers with a <em>new</em> certificate id and drops the old record (observed live), so the
     *       returned id is what is tracked from here on; falls back to an upload when there is nothing
     *       to update or the PATCH is refused;</li>
     *   <li><b>replace_delete</b> / <b>replace_keep</b>: {@code POST} a new custom certificate, then
     *       delete (or keep) each id of {@code replacedIds}.</li>
     * </ul>
     * Idempotent on retry: a certificate with the same expiry and hosts already present is treated
     * as the result of an earlier successful attempt.
     *
     * @param certPem       certificate file to upload (leaf, optionally followed by the ICA)
     * @param privateKeyPem sensor-generated private key, or null when {@code customCsrId} is used
     * @param customCsrId   Cloudflare CSR id whose key signs the leaf, or null
     * @param leaf          parsed end-entity certificate
     * @param replacedIds   custom certificate ids the install replaces (may be empty)
     */
    public Result<CloudflareInstalledCertificate> installCertificate(String certPem, String privateKeyPem,
                                                                     String customCsrId, X509Certificate leaf,
                                                                     List<String> replacedIds) {
        try {
            if ((privateKeyPem == null || privateKeyPem.isBlank()) && (customCsrId == null || customCsrId.isBlank())) {
                return Result.failure("Neither a private key nor a Cloudflare CSR id is available for the upload",
                        ErrorCode.CERTIFICATE_UPLOAD_ERROR.name());
            }
            final var serial = CertificateAttributesUtil.serialHex(leaf);
            final long notAfter = leaf.getNotAfter().toInstant().getEpochSecond();
            final var names = CertificateAttributesUtil.coveredNames(leaf);
            final var installed = new CloudflareInstalledCertificate();
            installed.setSerialNumber(serial);
            final List<String> targets = new ArrayList<>(new LinkedHashSet<>(
                    replacedIds == null ? List.of() : replacedIds.stream().filter(Objects::nonNull).toList()));

            final var before = listCertificates();
            // --- 0. retry detection: the leaf is already in the zone ---------------------------
            final var existing = before.stream()
                    .filter(c -> c.getExpiresOnEpoch() != null && Math.abs(c.getExpiresOnEpoch() - notAfter) <= 1)
                    .filter(c -> names.stream().anyMatch(n -> CertificateAttributesUtil.hostsCover(c.getHosts(), n)))
                    .findFirst();
            String id;
            if (existing.isPresent()) {
                id = existing.get().getId();
                installed.setAction("existing");
                log.warn("A custom certificate ('{}', expires {}) with this leaf's expiry and hostnames already exists - "
                        + "treating it as an earlier successful upload and only completing the rotation", id, existing.get().getExpiresOn());
                targets.remove(id);
            } else {
                id = null;
                // --- 1. update in place ----------------------------------------------------------
                if (config.isUpdateStrategy() && !targets.isEmpty()) {
                    final var target = targets.get(0);
                    final var patched = updateCertificate(target, certPem, privateKeyPem, customCsrId);
                    if (patched.isSuccess()) {
                        // Seen live (2026-10-12): Cloudflare answers the PATCH with a NEW custom certificate id
                        // and the old id stops existing at once (GET answers 400 code 1002). Always continue
                        // with the id Cloudflare returned, and make sure the old record is really gone.
                        final var returnedId = patched.getValue().getId();
                        id = returnedId == null || returnedId.isBlank() ? target : returnedId;
                        installed.setAction("update");
                        targets.remove(target);
                        if (!id.equals(target)) {
                            log.info("Cloudflare re-issued the custom certificate under a new id '{}' (was '{}')", id, target);
                            if (getCertificate(target).isPresent()) {
                                log.warn("The previous record '{}' still exists after the in-place update - deleting it so the "
                                        + "zone carries the renewed certificate once", target);
                                if (deleteCertificate(target)) {
                                    installed.getDeletedCertificates().add(target);
                                } else {
                                    installed.getRetainedCertificates().add(target);
                                }
                            } else {
                                log.info("Previous record '{}' is gone - Cloudflare replaced it", target);
                                installed.getDeletedCertificates().add(target);
                            }
                        }
                        if (!targets.isEmpty()) {
                            log.warn("More than one certificate matched the renewal ({}); '{}' was updated in place and the "
                                    + "others are left untouched", replacedIds, target);
                            installed.getRetainedCertificates().addAll(targets);
                            targets.clear();
                        }
                        final var result = patched.getValue();
                        if (result.getExpiresOnEpoch() != null && Math.abs(result.getExpiresOnEpoch() - notAfter) > 1) {
                            log.warn("After the update Cloudflare reports expires_on {} but the uploaded leaf expires at {}",
                                    result.getExpiresOn(), leaf.getNotAfter().toInstant());
                        }
                    } else {
                        log.error("Update in place of '{}' failed ({}); falling back to uploading a new certificate and "
                                + "deleting the replaced one", target, patched.getErrorMessage());
                    }
                }
                // --- 2. upload a new certificate -------------------------------------------------
                if (id == null) {
                    final var uploaded = uploadCertificate(certPem, privateKeyPem, customCsrId);
                    if (!uploaded.isSuccess()) {
                        return Result.failure(uploaded.getErrorMessage(), uploaded.getErrorCode());
                    }
                    id = uploaded.getValue().getId();
                    installed.setAction("upload");
                    targets.remove(id);
                }
            }
            installed.setCertificateId(id);

            // --- 3. wait for Cloudflare to activate it ---------------------------------------
            final var active = waitForActive(id, ACTIVE_WAIT_MILLIS);
            installed.setStatus(active.map(CloudflareCertificate::getStatus).orElse("unknown"));
            if (active.isEmpty()) {
                return Result.failure("Custom certificate '" + id + "' is not listed by Cloudflare after the upload",
                        ErrorCode.CERTIFICATE_UPLOAD_ERROR.name());
            }
            if (!active.get().isActive()) {
                log.warn("Custom certificate '{}' is still '{}' after {} ms; validateCertificate will re-check", id,
                        active.get().getStatus(), ACTIVE_WAIT_MILLIS);
            } else {
                // Cloudflare never reports a serial; ask the edge what it serves now (best effort, short budget).
                installed.setServedSerialNumber(probeServedSerial(active.get(), serial));
            }

            // --- 4. retire the replaced certificate(s) ---------------------------------------
            for (String old : targets) {
                if (old.equals(id)) {
                    continue;
                }
                if (config.isKeepReplaced()) {
                    log.info("Connector is set to keep replaced certificates - '{}' left in the zone", old);
                    installed.getRetainedCertificates().add(old);
                    continue;
                }
                if (config.isUpdateStrategy() && !"upload".equals(installed.getAction()) && !"existing".equals(installed.getAction())) {
                    installed.getRetainedCertificates().add(old);
                    continue;
                }
                if (getCertificate(old).isEmpty()) {
                    log.info("Replaced certificate '{}' is no longer present - nothing to delete", old);
                    continue;
                }
                if (deleteCertificate(old)) {
                    installed.getDeletedCertificates().add(old);
                } else {
                    installed.getRetainedCertificates().add(old);
                }
            }
            log.info("Install complete: id='{}', action={}, status={}, deleted={}, retained={}", id, installed.getAction(),
                    installed.getStatus(), installed.getDeletedCertificates(), installed.getRetainedCertificates());
            return Result.success(installed);
        } catch (CloudflareApiException e) {
            log.error("Error during installCertificate", e);
            return Result.failure(e.getMessage(), e.isUnauthorized() ? ErrorCode.UNAUTHORIZED.name()
                    : ErrorCode.CERTIFICATE_UPLOAD_ERROR.name());
        } catch (Exception e) {
            log.error("Error during installCertificate", e);
            return Result.failure(describe(e), ErrorCode.INTERNAL_ERROR.name());
        }
    }

    /** {@code POST /custom_certificates} with the connector's bundle method and type. */
    public Result<CloudflareCertificate> uploadCertificate(String certPem, String privateKeyPem, String customCsrId) {
        try {
            final ObjectNode payload = MAPPER.createObjectNode();
            payload.put("certificate", certPem);
            payload.put("bundle_method", config.effectiveBundleMethod());
            payload.put("type", config.effectiveCertificateType());
            if (customCsrId != null && !customCsrId.isBlank()) {
                payload.put("custom_csr_id", customCsrId);
            } else {
                payload.put("private_key", privateKeyPem);
            }
            log.info("Uploading new custom certificate: bundle_method={}, type={}, key={}", config.effectiveBundleMethod(),
                    config.effectiveCertificateType(), customCsrId != null ? "custom_csr_id " + customCsrId : "private_key (sensor)");
            final var response = client.postJson(config.zonePath() + CUSTOM_CERTIFICATES, MAPPER.writeValueAsString(payload));
            if (!CloudflareRestClient.isCloudflareSuccess(response)) {
                return Result.failure("Cloudflare rejected the certificate upload: " + CloudflareRestClient.describeFailure(response)
                        + hint(response), ErrorCode.CERTIFICATE_UPLOAD_ERROR.name());
            }
            final var c = parseCertificate(CloudflareRestClient.result(response));
            if (c.getId() == null) {
                return Result.failure("Cloudflare accepted the upload but returned no certificate id: "
                        + CloudflareRestClient.describeFailure(response), ErrorCode.CERTIFICATE_UPLOAD_ERROR.name());
            }
            log.info("Uploaded custom certificate '{}' (status={}, hosts={}, expires={})", c.getId(), c.getStatus(), c.getHosts(),
                    c.getExpiresOn());
            return Result.success(c);
        } catch (Exception e) {
            log.error("Error during uploadCertificate", e);
            return Result.failure(describe(e), ErrorCode.CERTIFICATE_UPLOAD_ERROR.name());
        }
    }

    /** {@code PATCH /custom_certificates/{id}}: replaces certificate (+ key / CSR id) in place; the id and priority are kept. */
    public Result<CloudflareCertificate> updateCertificate(String id, String certPem, String privateKeyPem, String customCsrId) {
        try {
            final ObjectNode payload = MAPPER.createObjectNode();
            payload.put("certificate", certPem);
            payload.put("bundle_method", config.effectiveBundleMethod());
            if (customCsrId != null && !customCsrId.isBlank()) {
                payload.put("custom_csr_id", customCsrId);
            } else {
                payload.put("private_key", privateKeyPem);
            }
            log.info("Updating custom certificate '{}' in place: bundle_method={}, key={}", id, config.effectiveBundleMethod(),
                    customCsrId != null ? "custom_csr_id " + customCsrId : "private_key (sensor)");
            final var response = client.patchJson(config.zonePath() + CUSTOM_CERTIFICATES + "/" + CloudflareRestClient.urlEncode(id),
                    MAPPER.writeValueAsString(payload));
            if (!CloudflareRestClient.isCloudflareSuccess(response)) {
                return Result.failure("Cloudflare rejected the in-place update of '" + id + "': "
                        + CloudflareRestClient.describeFailure(response) + hint(response), ErrorCode.CERTIFICATE_UPLOAD_ERROR.name());
            }
            final var c = parseCertificate(CloudflareRestClient.result(response));
            if (c.getId() == null) {
                c.setId(id);
            }
            log.info("Updated custom certificate '{}' (status={}, hosts={}, expires={})", c.getId(), c.getStatus(), c.getHosts(),
                    c.getExpiresOn());
            return Result.success(c);
        } catch (Exception e) {
            log.error("Error during updateCertificate", e);
            return Result.failure(describe(e), ErrorCode.CERTIFICATE_UPLOAD_ERROR.name());
        }
    }

    private String hint(java.net.http.HttpResponse<String> response) {
        final var msg = CloudflareRestClient.errorMessage(response.body());
        final var lower = msg == null ? "" : msg.toLowerCase(Locale.ROOT);
        if (lower.contains("chain") || lower.contains("intermediate")) {
            return " (with bundle method 'force' the uploaded file must contain the end-entity certificate followed by its issuing CA; "
                    + "with 'ubiquitous'/'optimal' the CA must be publicly trusted)";
        }
        if (lower.contains("private key") || lower.contains("key does not match") || lower.contains("mismatch")) {
            return " (the private key / CSR does not belong to this certificate - generateCsr and installCertificate must run on the same sensor and flow)";
        }
        if (lower.contains("plan") || lower.contains("entitle") || lower.contains("not available")) {
            return " (custom certificates require a Business or Enterprise zone plan)";
        }
        if (response.statusCode() == 403) {
            return " (the token needs Zone > SSL and Certificates > Edit on this zone)";
        }
        return "";
    }

    /** Polls the certificate until Cloudflare reports it {@code active} or {@code maxMillis} elapse; returns the last state seen. */
    public Optional<CloudflareCertificate> waitForActive(String id, long maxMillis) throws IOException, InterruptedException {
        final long deadline = System.currentTimeMillis() + maxMillis;
        Optional<CloudflareCertificate> last = Optional.empty();
        while (true) {
            last = getCertificate(id);
            if (last.isPresent() && last.get().isActive()) {
                return last;
            }
            // Only "pending" / "initializing" can still turn active; absent, expired or deleted will not.
            final var status = last.map(CloudflareCertificate::getStatus).map(String::toLowerCase).orElse("absent");
            if (!status.equals("pending") && !status.equals("initializing")) {
                return last;
            }
            if (System.currentTimeMillis() + ACTIVE_POLL_MILLIS > deadline) {
                return last;
            }
            log.info("Custom certificate '{}' is '{}' - waiting {} ms", id, last.map(CloudflareCertificate::getStatus).orElse("absent"),
                    ACTIVE_POLL_MILLIS);
            Thread.sleep(ACTIVE_POLL_MILLIS);
        }
    }

    public boolean deleteCertificate(String id) {
        try {
            log.info("Deleting replaced custom certificate '{}'", id);
            final var response = client.delete(config.zonePath() + CUSTOM_CERTIFICATES + "/" + CloudflareRestClient.urlEncode(id));
            if (CloudflareRestClient.isCloudflareSuccess(response)) {
                log.info("SUCCESS: replaced certificate '{}' deleted", id);
                return true;
            }
            log.warn("Could not delete replaced certificate '{}': {}", id, CloudflareRestClient.describeFailure(response));
            return false;
        } catch (Exception e) {
            log.warn("Could not delete replaced certificate '{}': {}", id, describe(e));
            return false;
        }
    }

    // ------------------------------------------------------------------ validateCertificate

    /**
     * Confirms the custom certificate exists, is {@code active}, and — when known — expires when
     * the issued leaf does. As a best effort the edge is probed so the served serial can be
     * compared with the expected one; a mismatch there is logged (propagation), not failed.
     */
    public Result<CloudflareCertificate> validateCertificate(String id, String expectedSerialHex, Long expectedNotAfterEpoch,
                                                             String zoneName) {
        try {
            final var entry = waitForActive(id, ACTIVE_WAIT_MILLIS).orElse(null);
            if (entry == null) {
                return Result.failure("Custom certificate '" + id + "' is not present in Cloudflare zone " + config.getZoneId(),
                        ErrorCode.CERTIFICATE_VALIDATION_ERROR.name());
            }
            if (!entry.isActive()) {
                return Result.failure("Custom certificate '" + id + "' has status '" + entry.getStatus() + "' in Cloudflare (expected 'active')",
                        ErrorCode.CERTIFICATE_VALIDATION_ERROR.name());
            }
            if (expectedNotAfterEpoch != null && entry.getExpiresOnEpoch() != null
                    && Math.abs(entry.getExpiresOnEpoch() - expectedNotAfterEpoch) > 60) {
                return Result.failure("Custom certificate '" + id + "' expires on " + entry.getExpiresOn()
                        + " but the certificate TLM issued expires at " + java.time.Instant.ofEpochSecond(expectedNotAfterEpoch)
                        + " - the zone does not carry the issued certificate", ErrorCode.CERTIFICATE_VALIDATION_ERROR.name());
            }
            final var pem = tryFetchCertificatePem(entry, zoneName, System.currentTimeMillis() + Math.min(8_000L, config.effectiveProbeBudgetMillis()));
            if (pem != null) {
                entry.setCertificatePem(pem);
                applyPem(entry);
                if (expectedSerialHex != null && !expectedSerialHex.isBlank()
                        && !CertificateAttributesUtil.sameSerial(entry.getSerialNumber(), expectedSerialHex)) {
                    log.warn("The Cloudflare edge currently serves serial {} for '{}' while TLM expects {} - the API reports the "
                            + "certificate active, so this is most likely edge propagation or another overlapping certificate "
                            + "with higher priority", entry.getSerialNumber(), id, expectedSerialHex);
                } else {
                    log.info("Edge probe confirmed '{}': serial {} is being served", id, entry.getSerialNumber());
                }
            }
            log.info("Validated '{}': status={}, hosts={}, expires={}, issuer={}", id, entry.getStatus(), entry.getHosts(),
                    entry.getExpiresOn(), entry.getIssuer());
            return Result.success(entry);
        } catch (CloudflareApiException e) {
            log.error("Error during validateCertificate for {}", id, e);
            return Result.failure(e.getMessage(), e.isUnauthorized() ? ErrorCode.UNAUTHORIZED.name()
                    : ErrorCode.CERTIFICATE_VALIDATION_ERROR.name());
        } catch (Exception e) {
            log.error("Error during validateCertificate for {}", id, e);
            return Result.failure(describe(e), ErrorCode.INTERNAL_ERROR.name());
        }
    }

    /**
     * Performs a short TLS probe for the certificate's hosts and returns the serial the edge is
     * serving (null when nothing could be fetched). Logs whether it matches {@code expectedSerial};
     * a mismatch right after an install is usually edge propagation and is not treated as an error.
     */
    String probeServedSerial(CloudflareCertificate entry, String expectedSerial) {
        if (config.effectiveProbeBudgetMillis() <= 0) {
            return null;
        }
        try {
            String zoneName = null;
            try {
                zoneName = getZone().getName();
            } catch (Exception e) {
                log.debug("Zone name unavailable for the edge probe: {}", e.getMessage());
            }
            final var deadline = System.currentTimeMillis() + Math.min(6_000L, config.effectiveProbeBudgetMillis());
            final var copy = new CloudflareCertificate();
            copy.setId(entry.getId());
            copy.setHosts(entry.getHosts());
            copy.setStatus(entry.getStatus());
            copy.setExpiresOn(entry.getExpiresOn());
            copy.setExpiresOnEpoch(entry.getExpiresOnEpoch());
            final var pem = tryFetchCertificatePem(copy, zoneName, deadline);
            if (pem == null) {
                // The edge may still serve the previous certificate: probe once more without the expiry filter
                // so the log can say what IS being served.
                final var fallback = new CloudflareCertificate();
                fallback.setId(entry.getId());
                fallback.setHosts(entry.getHosts());
                fallback.setStatus("active");
                final var servedPem = tryFetchCertificatePem(fallback, zoneName, System.currentTimeMillis() + 4_000L);
                if (servedPem != null) {
                    final var served = CloudflareAutomationPluginHelper.parseFirstCertificate(servedPem);
                    log.warn("Edge probe: {} currently serves serial {} (expires {}) while the installed certificate has serial {} - "
                            + "most likely edge propagation; validateCertificate will re-check",
                            entry.getHosts(), CertificateAttributesUtil.serialHex(served), served.getNotAfter().toInstant(), expectedSerial);
                    return CertificateAttributesUtil.serialHex(served);
                }
                log.info("Edge probe: no certificate could be fetched for {} within the budget", entry.getHosts());
                return null;
            }
            final var served = CloudflareAutomationPluginHelper.parseFirstCertificate(pem);
            final var servedSerial = CertificateAttributesUtil.serialHex(served);
            if (CertificateAttributesUtil.sameSerial(servedSerial, expectedSerial)) {
                log.info("Edge probe confirmed: {} now serves the installed certificate, serial {}", entry.getHosts(), servedSerial);
            } else {
                log.warn("Edge probe: {} serves serial {} but the installed certificate has serial {}", entry.getHosts(),
                        servedSerial, expectedSerial);
            }
            return servedSerial;
        } catch (Exception e) {
            log.info("Edge probe after install skipped: {}", e.getMessage());
            return null;
        }
    }

    // ------------------------------------------------------------------ misc

    private static String firstNonBlank(String... values) {
        for (String v : values) {
            if (v != null && !v.isBlank()) {
                return v.trim();
            }
        }
        return null;
    }

    private static String describe(Exception e) {
        final var msg = e.getMessage();
        return Objects.requireNonNullElse(msg, e.getClass().getSimpleName());
    }
}
