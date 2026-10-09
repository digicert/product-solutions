package com.example.automation.adapter;

import java.io.IOException;
import java.net.InetSocketAddress;
import java.net.Socket;
import java.nio.charset.StandardCharsets;
import java.security.SecureRandom;
import java.security.cert.Certificate;
import java.security.cert.X509Certificate;
import java.time.OffsetDateTime;
import java.util.ArrayList;
import java.util.Base64;
import java.util.Iterator;
import java.util.LinkedHashMap;
import java.util.LinkedHashSet;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Objects;
import java.util.Optional;
import java.util.Set;
import java.util.TreeSet;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

import javax.net.ssl.SNIHostName;
import javax.net.ssl.SSLContext;
import javax.net.ssl.SSLSocket;
import javax.net.ssl.TrustManager;
import javax.net.ssl.X509TrustManager;

import com.example.automation.helper.CertificateAttributesUtil;
import com.example.automation.helper.FortiGateAutomationPluginHelper;
import com.example.automation.model.CertificateReference;
import com.example.automation.model.Connection;
import com.example.automation.model.ErrorCode;
import com.example.automation.model.FortiGateCertificate;
import com.example.automation.model.FortiGateConfigurationData;
import com.example.automation.model.FortiGateInstalledCertificate;
import com.example.automation.model.Result;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.node.ArrayNode;
import com.fasterxml.jackson.databind.node.ObjectNode;

import lombok.extern.slf4j.Slf4j;

/**
 * Drives all certificate-lifecycle operations against a single FortiGate over the FortiOS REST API
 * ({@code /api/v2}). The endpoints and the rotation strategy follow the DigiCert
 * {@code fortigate-awr.sh} post-enrollment automation:
 *
 * <pre>
 *   GET    /cmdb/vpn.certificate/local?{scope}&with_meta=1          local certificates (range, source, q_ref, PEM)
 *   GET    /monitor/system/available-certificates?{scope}           certificate metadata (subject, validity, key type, status)
 *   GET    /monitor/system/certificate/download?mkey=N&type=local-cer&{scope}   PEM download (fallback)
 *   POST   /monitor/vpn-certificate/local/import?vdom=V             JSON import (cert + key, base64)
 *   GET    /cmdb/vpn.ssl/settings, system/global, user/setting, system/ftm-push        singleton references
 *   GET    /cmdb/vpn.ipsec/phase1-interface, vpn.ipsec/phase1, firewall/vip, firewall/ssl-ssh-profile   table references
 *   PUT    …?vdom=V   body {"<field>": "<new>"} or {"<field>": [{"name": "<new>"}]}      repoint a reference
 *   DELETE /cmdb/vpn.certificate/local/OLD?{scope}                  delete an unreferenced certificate
 * </pre>
 * where {@code {scope}} is {@code scope=global} or {@code vdom=<name>} depending on the connector.
 *
 * <p><b>Rotate, don't overwrite.</b> FortiOS cannot overwrite an existing local certificate (the
 * import fails as a duplicate) and refuses to delete a certificate while any object references it.
 * So a renewal imports the new certificate under a <em>unique</em> name, repoints every reference
 * to it, and only then deletes the old certificate — guarded by FortiOS's own reference count
 * ({@code q_ref}) and by FortiOS itself refusing to delete an in-use object.
 */
@Slf4j
public class FortiGateAdapter {

    static final String MON_STATUS = "/monitor/system/status";
    static final String MON_AVAILABLE_CERTS = "/monitor/system/available-certificates";
    static final String MON_CERT_DOWNLOAD = "/monitor/system/certificate/download";
    static final String MON_CERT_IMPORT = "/monitor/vpn-certificate/local/import";
    static final String CMDB_LOCAL_CERT = "/cmdb/vpn.certificate/local";
    static final String CMDB_SSL_SETTINGS = "/cmdb/vpn.ssl/settings";

    /** Singleton objects that hold one certificate reference: type, cmdb path, field. */
    private static final Object[][] SINGLETON_REFS = {
        { CertificateReference.Type.SSL_VPN, "vpn.ssl/settings", "servercert" },
        { CertificateReference.Type.ADMIN_HTTPS, "system/global", "admin-server-cert" },
        { CertificateReference.Type.USER_AUTH, "user/setting", "auth-cert" },
        { CertificateReference.Type.FTM_PUSH, "system/ftm-push", "server-cert" },
    };

    /** Table objects whose entries hold a certificate reference (string or list): type, cmdb path, field. */
    private static final Object[][] TABLE_REFS = {
        { CertificateReference.Type.IPSEC_PHASE1_INTERFACE, "vpn.ipsec/phase1-interface", "certificate" },
        { CertificateReference.Type.IPSEC_PHASE1, "vpn.ipsec/phase1", "certificate" },
        { CertificateReference.Type.FIREWALL_VIP, "firewall/vip", "ssl-certificate" },
        { CertificateReference.Type.SSL_SSH_PROFILE, "firewall/ssl-ssh-profile", "server-cert" },
    };

    private static final ObjectMapper MAPPER = new ObjectMapper();
    private static final Pattern PEM_CERT = Pattern.compile(
            "-----BEGIN CERTIFICATE-----[\\s\\S]+?-----END CERTIFICATE-----");

    private final FortiGateRestClient client;
    private final AdapterConfig config;

    public FortiGateAdapter(AdapterConfig config) {
        this.config = config;
        this.client = new FortiGateRestClient(config);
    }

    // ------------------------------------------------------------------ testConnection

    public Result<Connection> testConnection() {
        try {
            final var response = client.get(certPath(CMDB_LOCAL_CERT, "with_meta=1"));
            if (response.statusCode() == 401 || response.statusCode() == 403) {
                return Result.failure("Unauthorized: the FortiGate rejected the REST API token ("
                        + FortiGateRestClient.describeFailure(response) + "). Check the token, the REST API "
                        + "administrator's profile and its trusted hosts.", ErrorCode.UNAUTHORIZED.name());
            }
            if (!FortiGateRestClient.isFortiGateSuccess(response)) {
                return Result.failure("FortiGate API error listing certificates: "
                        + FortiGateRestClient.describeFailure(response), ErrorCode.FORTIGATE_API_ERROR.name());
            }
            final var certs = listCertificates();
            final var status = firstResult(getQuiet(FortiGateRestClient.withQuery(MON_STATUS, config.vdomQuery())));
            log.info("testConnection OK: {} local certificate(s) in scope '{}' on {} (hostname={}, version={})",
                    certs.size(), config.importScope(), config.getHost(), status.path("hostname").asText("?"),
                    versionOf(getQuiet(FortiGateRestClient.withQuery(MON_STATUS, config.vdomQuery()))));
            return Result.success(new Connection(true));
        } catch (Exception e) {
            log.error("Error during testConnection", e);
            return Result.failure(describe(e), ErrorCode.INTERNAL_ERROR.name());
        }
    }

    // ------------------------------------------------------------------ refreshConfiguration

    /**
     * Builds the inventory: every local certificate in the managed scope plus where it is
     * referenced. Every certificate is surfaced — including expired, factory and unreferenced ones,
     * which are exactly the certificates an operator wants to replace. The certificate body comes
     * from the cmdb entry when FortiOS returns it there, else from the fallbacks in
     * {@link #tryFetchCertificatePem}.
     */
    public Result<FortiGateConfigurationData> getConfigurationData() {
        try {
            final var data = new FortiGateConfigurationData();
            data.setHost(config.getHost());
            data.setPort(config.getPort());
            data.setVersion(versionOf(getQuiet(FortiGateRestClient.withQuery(MON_STATUS, config.vdomQuery()))));

            final List<FortiGateCertificate> certs = new ArrayList<>();
            for (FortiGateCertificate cert : listCertificates()) {
                if (cert.isCaCertificate()) {
                    // Fortinet_CA_SSL & co. are CA certificates for SSL inspection - not TLS server
                    // certificates TLM could renew, so they are not surfaced as assets.
                    log.info("Skipping CA certificate '{}' (type local-ca)", cert.getName());
                    continue;
                }
                certs.add(cert);
            }
            final var references = collectReferences();
            data.setReferences(references);

            for (FortiGateCertificate cert : certs) {
                final var refs = references.getOrDefault(cert.getName(), List.of());
                cert.setCertificatePem(tryFetchCertificatePem(cert, refs));
                applyPem(cert);
                log.info("Discovered certificate: name={}, cn={}, source={}, range={}, key={}/{}, status={}, validTo={}, "
                        + "q_ref={}, references={}, pem={}",
                        cert.getName(), cert.getCommonName(), cert.getSource(), cert.getRange(), cert.getKeyType(),
                        cert.getKeySize(), cert.getStatus(), cert.getValidTo(), cert.getRefCount(), refs,
                        cert.getCertificatePem() != null ? "yes" : "no");
            }
            data.setCertificates(certs);
            log.info("RefreshConfiguration discovered {} certificate(s) on {} (FortiOS {})", certs.size(),
                    config.getHost(), data.getVersion());
            return Result.success(data);
        } catch (Exception e) {
            log.error("Error during getConfigurationData", e);
            return Result.failure(describe(e), ErrorCode.FORTIGATE_API_ERROR.name());
        }
    }

    // ------------------------------------------------------------------ installCertificate

    /**
     * Imports the renewed certificate under {@code requestedName} (made unique if taken), repoints
     * every reference of each {@code oldCertNames} entry to it, and deletes the old certificates
     * once they are unreferenced (unless {@code keepReplaced}).
     *
     * <p>Idempotent on retry: if {@code requestedName} already exists and carries the same serial as
     * {@code leaf}, the import is skipped and only the rotation is (re)run.
     *
     * @param certFilePem content of the certificate file to upload (leaf, optionally followed by ICAs)
     * @param keyPem      unencrypted PKCS#8 private key matching the leaf
     * @param leaf        parsed end-entity certificate (for serial / algorithm checks)
     */
    public Result<FortiGateInstalledCertificate> installCertificate(String requestedName, String certFilePem,
                                                                    String keyPem, X509Certificate leaf,
                                                                    List<String> oldCertNames,
                                                                    boolean keepReplaced) {
        try {
            final var leafSerial = CertificateAttributesUtil.serialHex(leaf);
            final var before = listCertificates();
            final Set<String> beforeNames = new TreeSet<>();
            before.forEach(c -> beforeNames.add(c.getName()));

            // --- 1. import (or detect an earlier successful import of the same certificate) -----
            String newName = requestedName;
            final var existing = before.stream().filter(c -> requestedName.equals(c.getName())).findFirst();
            if (existing.isPresent() && CertificateAttributesUtil.sameSerial(existing.get().getSerialNumber(), leafSerial)) {
                log.warn("Certificate '{}' with serial {} already exists on the FortiGate - skipping import, "
                        + "continuing with rotation", requestedName, leafSerial);
            } else {
                newName = uniqueName(requestedName, beforeNames);
                if (!newName.equals(requestedName)) {
                    log.warn("Name '{}' is already taken by a different certificate; importing as '{}'",
                            requestedName, newName);
                }
                log.info("Existing certificates on the FortiGate: {}", beforeNames);
                log.info("Importing certificate as '{}' (serial {}, scope {})", newName, leafSerial, config.importScope());

                final ObjectNode payload = MAPPER.createObjectNode();
                payload.put("type", "regular");
                payload.put("scope", config.importScope());
                payload.put("certname", newName);
                payload.put("file_content", Base64.getEncoder().encodeToString(certFilePem.getBytes(StandardCharsets.UTF_8)));
                payload.put("key_file_content", Base64.getEncoder().encodeToString(keyPem.getBytes(StandardCharsets.UTF_8)));
                final var response = client.postJson(FortiGateRestClient.withQuery(MON_CERT_IMPORT, config.vdomQuery()),
                        MAPPER.writeValueAsString(payload));
                if (!FortiGateRestClient.isFortiGateSuccess(response)) {
                    return Result.failure("FortiGate rejected the certificate import: "
                            + FortiGateRestClient.describeFailure(response)
                            + (response.statusCode() == 500 || response.statusCode() == 400
                                    ? " (usually the certificate/key are invalid or mismatched, or the name already exists)"
                                    : ""),
                            ErrorCode.CERTIFICATE_IMPORT_ERROR.name());
                }
                log.info("Import accepted: {}", FortiGateRestClient.describeFailure(response));

                // --- 2. confirm the name FortiOS actually assigned ----------------------------
                sleepQuietly(1000);
                final var after = listCertificates();
                final var added = new TreeSet<String>();
                after.forEach(c -> { if (!beforeNames.contains(c.getName())) { added.add(c.getName()); } });
                if (added.contains(newName)) {
                    log.info("FortiGate stored the new certificate as '{}'", newName);
                } else if (added.size() == 1) {
                    newName = added.first();
                    log.warn("FortiGate stored the new certificate under '{}' rather than '{}'", newName, requestedName);
                } else {
                    return Result.failure("Import returned success but the new certificate '" + newName
                            + "' did not appear in the FortiGate certificate list for scope '" + config.importScope()
                            + "' (new names seen: " + added + ")", ErrorCode.CERTIFICATE_IMPORT_ERROR.name());
                }
            }

            final var installed = new FortiGateInstalledCertificate();
            installed.setCertificateName(newName);
            installed.setSerialNumber(leafSerial);

            final var newEntry = findCertificate(newName).orElse(null);
            if (newEntry != null && CertificateAttributesUtil.parseSerial(newEntry.getSerialNumber()) != null
                    && !CertificateAttributesUtil.sameSerial(newEntry.getSerialNumber(), leafSerial)) {
                log.warn("Serial reported by FortiGate for '{}' ({}) differs from the uploaded leaf ({}); "
                        + "continuing on the strength of the list diff", newName, newEntry.getSerialNumber(), leafSerial);
            }

            // --- 3. rotate references off each previous certificate --------------------------
            final List<String> failures = new ArrayList<>();
            int repointed = 0;
            for (String oldName : new LinkedHashSet<>(oldCertNames)) {
                if (oldName == null || oldName.isBlank() || oldName.equals(newName)) {
                    continue;
                }
                final var oldEntry = findCertificate(oldName).orElse(null);
                if (oldEntry == null) {
                    log.info("Previous certificate '{}' is not present on the FortiGate - nothing to rotate", oldName);
                    continue;
                }
                log.info("Processing previous certificate '{}' (source={}, key={}, q_ref={})", oldName,
                        oldEntry.getSource(), oldEntry.getKeyType(), oldEntry.getRefCount());

                final var refs = collectReferences().getOrDefault(oldName, List.of());
                if (refs.isEmpty()) {
                    log.info("Certificate '{}' is not referenced by any object this plugin scans", oldName);
                }
                boolean allOk = true;
                for (CertificateReference ref : refs) {
                    if (repoint(ref, oldName, newName)) {
                        repointed++;
                    } else {
                        failures.add(ref.toString());
                        allOk = false;
                    }
                }
                if (!refs.isEmpty()) {
                    log.info("Waiting 2 seconds for FortiOS to apply the new binding(s)...");
                    sleepQuietly(2000);
                }

                // --- 4. delete the old certificate once it is unreferenced ---------------------
                if (!allOk) {
                    log.error("One or more references to '{}' could not be repointed - leaving it in place", oldName);
                    installed.getRetainedCertificates().add(oldName);
                    continue;
                }
                if (keepReplaced) {
                    log.info("Connector is set to keep replaced certificates - '{}' left in place", oldName);
                    installed.getRetainedCertificates().add(oldName);
                    continue;
                }
                if (oldEntry.isFactory()) {
                    log.info("'{}' is a FortiOS built-in certificate - it cannot be deleted and is left in place", oldName);
                    installed.getRetainedCertificates().add(oldName);
                    continue;
                }
                final var recheck = findCertificate(oldName).orElse(null);
                if (recheck == null) {
                    log.info("'{}' no longer present - nothing to delete", oldName);
                    continue;
                }
                if (recheck.isKnownReferenced()) {
                    log.warn("SKIP delete: '{}' still reports q_ref={} (an object this plugin does not scan still "
                            + "references it) - leaving it in place for manual review", oldName, recheck.getRefCount());
                    installed.getRetainedCertificates().add(oldName);
                    continue;
                }
                if (deleteCertificate(oldName)) {
                    installed.getDeletedCertificates().add(oldName);
                } else {
                    installed.getRetainedCertificates().add(oldName);
                }
            }
            installed.setReferencesRepointed(repointed);

            if (!failures.isEmpty()) {
                return Result.failure("Certificate '" + newName + "' was imported but " + failures.size()
                        + " reference(s) to the previous certificate could not be repointed: " + failures
                        + ". The previous certificate was left in place.",
                        ErrorCode.CERTIFICATE_ROTATION_ERROR.name());
            }
            log.info("Rotation complete: new='{}', repointed={}, deleted={}, retained={}", newName, repointed,
                    installed.getDeletedCertificates(), installed.getRetainedCertificates());
            return Result.success(installed);
        } catch (Exception e) {
            log.error("Error during installCertificate", e);
            return Result.failure(describe(e), ErrorCode.INTERNAL_ERROR.name());
        }
    }

    // ------------------------------------------------------------------ validateCertificate

    /**
     * Confirms {@code name} is present on the FortiGate, not reported as expired/pending, and —
     * when {@code expectedSerialHex} is known and comparable — that the serials agree. Returns the
     * list entry with the PEM filled from {@link #tryFetchCertificatePem} when possible.
     */
    public Result<FortiGateCertificate> validateCertificate(String name, String expectedSerialHex) {
        try {
            final var entry = findCertificate(name).orElse(null);
            if (entry == null) {
                return Result.failure("Certificate '" + name + "' is not present on FortiGate " + config.getHost()
                        + " (scope " + config.importScope() + ")", ErrorCode.CERTIFICATE_VALIDATION_ERROR.name());
            }
            final var status = entry.getStatus() == null ? "" : entry.getStatus().trim().toLowerCase(Locale.ROOT);
            if (status.contains("expired") || status.contains("pending") || status.contains("invalid")) {
                return Result.failure("Certificate '" + name + "' has status '" + entry.getStatus() + "' on the FortiGate",
                        ErrorCode.CERTIFICATE_VALIDATION_ERROR.name());
            }
            if (expectedSerialHex != null && !expectedSerialHex.isBlank()
                    && CertificateAttributesUtil.parseSerial(entry.getSerialNumber()) != null
                    && !CertificateAttributesUtil.sameSerial(entry.getSerialNumber(), expectedSerialHex)) {
                return Result.failure("Certificate '" + name + "' on the FortiGate has serial " + entry.getSerialNumber()
                        + " but TLM expected " + expectedSerialHex, ErrorCode.CERTIFICATE_VALIDATION_ERROR.name());
            }
            final var refs = collectReferences().getOrDefault(name, List.of());
            entry.setCertificatePem(tryFetchCertificatePem(entry, refs));
            log.info("Validated '{}': status={}, serial={}, validTo={}, references={}", name, entry.getStatus(),
                    entry.getSerialNumber(), entry.getValidTo(), refs);
            return Result.success(entry);
        } catch (Exception e) {
            log.error("Error during validateCertificate for {}", name, e);
            return Result.failure(describe(e), ErrorCode.INTERNAL_ERROR.name());
        }
    }

    // ------------------------------------------------------------------ certificate list

    /**
     * Local certificates in the managed scope, merged from the cmdb table (authoritative for
     * existence, {@code q_ref}, {@code range}, {@code source} and — where FortiOS returns it — the
     * PEM) and the monitor view (subject, validity, key type, status). When a PEM is available the
     * X.509 fields are parsed from it.
     */
    public List<FortiGateCertificate> listCertificates() throws IOException, InterruptedException {
        final var response = client.get(certPath(CMDB_LOCAL_CERT, "with_meta=1"));
        if (!FortiGateRestClient.isFortiGateSuccess(response)) {
            throw new IOException("Listing FortiGate certificates failed: " + FortiGateRestClient.describeFailure(response));
        }
        final Map<String, JsonNode> monitor = new LinkedHashMap<>();
        for (JsonNode n : results(getQuiet(certPath(MON_AVAILABLE_CERTS, null)))) {
            // FortiOS 7.6 reports "local-cer" (server certificate) and "local-ca"; older builds "local".
            final var type = n.path("type").asText("local").toLowerCase(Locale.ROOT);
            final var name = nameOf(n);
            if (name != null && type.startsWith("local")) {
                monitor.put(name, n);
            }
        }
        final Map<String, FortiGateCertificate> certs = new LinkedHashMap<>();
        for (JsonNode n : results(FortiGateRestClient.json(response.body()))) {
            final var name = nameOf(n);
            if (name == null) {
                continue;
            }
            final var c = new FortiGateCertificate();
            c.setName(name);
            c.setRange(n.path("range").asText(null));
            c.setSource(n.path("source").asText(null));
            c.setRefCount(n.hasNonNull("q_ref") ? n.path("q_ref").asInt() : null);
            final var pem = n.path("certificate").asText("");
            if (pem.contains("-----BEGIN CERTIFICATE-----")) {
                final Matcher m = PEM_CERT.matcher(pem.replace("\\n", "\n"));
                if (m.find()) {
                    c.setCertificatePem(m.group().strip() + "\n");
                }
            }
            applyMonitor(c, monitor.get(name));
            applyPem(c);
            certs.put(name, c);
        }
        // Monitor-only entries (e.g. built-in certificates hidden from the cmdb table on some firmware).
        for (var e : monitor.entrySet()) {
            if (!certs.containsKey(e.getKey())) {
                final var c = new FortiGateCertificate();
                c.setName(e.getKey());
                applyMonitor(c, e.getValue());
                certs.put(e.getKey(), c);
            }
        }
        return new ArrayList<>(certs.values());
    }

    public Optional<FortiGateCertificate> findCertificate(String name) throws IOException, InterruptedException {
        return listCertificates().stream().filter(c -> name.equals(c.getName())).findFirst();
    }

    /** Copies the monitor view's metadata onto the entry (tolerant of the field-name variants seen across firmware). */
    static void applyMonitor(FortiGateCertificate c, JsonNode m) {
        if (m == null || m.isMissingNode()) {
            return;
        }
        if (c.getSource() == null) {
            c.setSource(m.path("source").asText(null));
        }
        if (c.getRange() == null) {
            c.setRange(m.path("range").asText(null));
        }
        if (c.getRefCount() == null && m.hasNonNull("q_ref")) {
            c.setRefCount(m.path("q_ref").asInt());
        }
        c.setKeyType(FortiGateCertificate.keyTypeLabel(firstText(m, "key_type", "keyType", "pkey_type")));
        if (m.path("key_size").isNumber()) {
            c.setKeySize(m.path("key_size").asInt());
        }
        c.setStatus(firstText(m, "status"));
        // FortiOS 7.6.7: "valid_to" is the epoch (number) and "valid_to_raw" the printable
        // "2036-09-14 12:22:21  GMT"; be tolerant of either being either.
        c.setValidFrom(dateText(m, "valid_from_raw", "valid_from", "validFrom", "not_before"));
        c.setValidTo(dateText(m, "valid_to_raw", "valid_to", "validTo", "not_after"));
        final Long epoch = epochOf(m, "valid_to", "valid_to_raw");
        if (epoch != null) {
            c.setValidToEpoch(epoch);
        }
        c.setSerialNumber(firstText(m, "serial_number", "serialNumber", "serial"));
        final var subjectRaw = firstText(m, "subject_raw");
        c.setSubject(subjectRaw != null ? subjectRaw : dnText(m.path("subject")));
        final var issuerRaw = firstText(m, "issuer_raw");
        c.setIssuer(issuerRaw != null ? issuerRaw : dnText(m.path("issuer")));
        final var cn = m.path("subject").path("CN").asText(null);
        if (cn != null && !cn.isBlank()) {
            c.setCommonName(cn);
        }
        if (m.has("is_built_in")) {
            c.setBuiltIn(m.path("is_built_in").asBoolean());
        }
        if (m.has("is_default_local")) {
            c.setDefaultLocal(m.path("is_default_local").asBoolean());
        }
        final var type = m.path("type").asText("").toLowerCase(Locale.ROOT);
        if (m.has("is_ca") || !type.isEmpty()) {
            c.setCa(m.path("is_ca").asBoolean(false) || type.equals("local-ca"));
        }
        final var fp = firstText(m, "fingerprint");
        if (fp != null) {
            final var hex = fp.replaceAll("[^0-9A-Fa-f]", "").toUpperCase(Locale.ROOT);
            if (hex.length() == 64) {
                c.setFingerprintSha256(hex);
            }
        }
    }

    /** First of the fields that holds a printable (non-numeric) date, else the first numeric one as ISO instant. */
    private static String dateText(JsonNode m, String... fields) {
        for (String f : fields) {
            final var v = m.path(f);
            if (v.isTextual() && !v.asText().isBlank()) {
                return v.asText().trim();
            }
        }
        for (String f : fields) {
            final var v = m.path(f);
            if (v.isNumber()) {
                return java.time.Instant.ofEpochSecond(v.asLong()).toString();
            }
        }
        return null;
    }

    private static Long epochOf(JsonNode m, String... fields) {
        for (String f : fields) {
            final var v = m.path(f);
            if (v.isNumber()) {
                return v.asLong();
            }
            if (v.isTextual() && v.asText().matches("\\d{9,}")) {
                return Long.parseLong(v.asText());
            }
        }
        return null;
    }

    /** When the PEM is known, the X.509 fields parsed from it take precedence over anything FortiOS printed. */
    static void applyPem(FortiGateCertificate c) {
        if (c.getCertificatePem() == null) {
            return;
        }
        try {
            final var x = FortiGateAutomationPluginHelper.parseFirstCertificate(c.getCertificatePem());
            c.setSubject(x.getSubjectX500Principal().getName());
            c.setIssuer(x.getIssuerX500Principal().getName());
            c.setCommonName(CertificateAttributesUtil.getCommonName(x.getSubjectX500Principal().getName()));
            c.setSerialNumber(CertificateAttributesUtil.serialHex(x));
            c.setValidFrom(x.getNotBefore().toInstant().toString());
            c.setValidTo(x.getNotAfter().toInstant().toString());
            c.setValidToEpoch(x.getNotAfter().toInstant().getEpochSecond());
            c.setKeyType(CertificateAttributesUtil.keyTypeOf(x));
            if (x.getPublicKey() instanceof java.security.interfaces.RSAPublicKey rsa) {
                c.setKeySize(rsa.getModulus().bitLength());
            } else if (x.getPublicKey() instanceof java.security.interfaces.ECPublicKey ec) {
                c.setKeySize(ec.getParams().getCurve().getField().getFieldSize());
            }
        } catch (Exception e) {
            log.warn("Certificate '{}' carries a body that does not parse as X.509 ({}) - ignoring it", c.getName(), e.getMessage());
            c.setCertificatePem(null);
        }
    }

    /** Monitor DNs are either an object ({@code {"C":"US","CN":"…"}}) or a string. */
    private static String dnText(JsonNode dn) {
        if (dn == null || dn.isMissingNode() || dn.isNull()) {
            return null;
        }
        if (dn.isTextual()) {
            return dn.asText();
        }
        if (dn.isObject()) {
            final var sb = new StringBuilder();
            dn.fields().forEachRemaining(e -> {
                if (sb.length() > 0) {
                    sb.append(", ");
                }
                sb.append(e.getKey()).append(" = ").append(e.getValue().asText());
            });
            return sb.toString();
        }
        return dn.toString();
    }

    // ------------------------------------------------------------------ references

    /**
     * Scans the singleton and table objects listed in {@link #SINGLETON_REFS} / {@link #TABLE_REFS}
     * and returns, per local certificate name, every place it is referenced. Objects that cannot be
     * read (feature disabled, profile permission missing, table absent on this firmware) are logged
     * and skipped, so a single odd object never aborts discovery.
     */
    public Map<String, List<CertificateReference>> collectReferences() {
        final Map<String, List<CertificateReference>> refs = new LinkedHashMap<>();
        for (Object[] def : SINGLETON_REFS) {
            final var type = (CertificateReference.Type) def[0];
            final var path = (String) def[1];
            final var field = (String) def[2];
            final var node = firstResult(getQuiet(FortiGateRestClient.withQuery("/cmdb/" + path, config.vdomQuery())));
            final var value = node.path(field);
            final var names = namesIn(value);
            log.info("{} ({}) {}={}", type, path, field, value.isMissingNode() ? "<absent>" : value.toString());
            for (String cert : names) {
                refs.computeIfAbsent(cert, k -> new ArrayList<>()).add(
                        new CertificateReference(type, path, null, field, value.isArray(), cert));
            }
        }
        for (Object[] def : TABLE_REFS) {
            final var type = (CertificateReference.Type) def[0];
            final var path = (String) def[1];
            final var field = (String) def[2];
            for (JsonNode entry : results(getQuiet(FortiGateRestClient.withQuery("/cmdb/" + path, config.vdomQuery())))) {
                final var mkey = nameOf(entry);
                final var value = entry.path(field);
                final var names = namesIn(value);
                if (mkey == null || names.isEmpty()) {
                    continue;
                }
                log.info("{} '{}' {}={}", type, mkey, field, value.toString());
                for (String cert : names) {
                    refs.computeIfAbsent(cert, k -> new ArrayList<>()).add(
                            new CertificateReference(type, path, mkey, field, value.isArray(), cert));
                }
            }
        }
        return refs;
    }

    /** Certificate names held by a reference attribute: a string, or a list of {@code {"name": …}}. */
    private static List<String> namesIn(JsonNode value) {
        final List<String> names = new ArrayList<>();
        if (value == null || value.isMissingNode() || value.isNull()) {
            return names;
        }
        if (value.isTextual()) {
            if (!value.asText().isBlank()) {
                names.add(value.asText());
            }
        } else if (value.isArray()) {
            for (JsonNode member : value) {
                final var n = member.isTextual() ? member.asText() : firstText(member, "name", "q_origin_key");
                if (n != null && !n.isBlank()) {
                    names.add(n);
                }
            }
        }
        return names;
    }

    /**
     * Repoints one reference from {@code oldCert} to {@code newCert}; true on success. List-valued
     * attributes are re-read and rewritten with only the matching member replaced, so a tunnel or
     * VIP that lists several certificates keeps the others.
     */
    boolean repoint(CertificateReference ref, String oldCert, String newCert) {
        final var path = ref.isSingleton()
                ? FortiGateRestClient.withQuery("/cmdb/" + ref.getPath(), config.vdomQuery())
                : FortiGateRestClient.withQuery("/cmdb/" + ref.getPath() + "/" + FortiGateRestClient.urlEncode(ref.getMkey()),
                        config.vdomQuery());
        try {
            final ObjectNode body = MAPPER.createObjectNode();
            if (ref.isListValued()) {
                final var current = firstResult(getQuiet(path)).path(ref.getField());
                final ArrayNode list = MAPPER.createArrayNode();
                final Set<String> seen = new LinkedHashSet<>();
                for (String n : namesIn(current)) {
                    seen.add(n.equals(oldCert) ? newCert : n);
                }
                if (seen.isEmpty()) {
                    seen.add(newCert);
                }
                for (String n : seen) {
                    list.add(MAPPER.createObjectNode().put("name", n));
                }
                body.set(ref.getField(), list);
            } else {
                body.put(ref.getField(), newCert);
            }
            final var json = MAPPER.writeValueAsString(body);
            log.info("Repointing {} from '{}' to '{}' : PUT {} body={}", ref, oldCert, newCert, path, json);
            final var response = client.putJson(path, json);
            if (FortiGateRestClient.isFortiGateSuccess(response)) {
                log.info("{} successfully repointed to '{}'", ref, newCert);
                return true;
            }
            log.error("Failed to repoint {}: {}", ref, FortiGateRestClient.describeFailure(response));
            return false;
        } catch (Exception e) {
            log.error("Failed to repoint {}: {}", ref, describe(e));
            return false;
        }
    }

    boolean deleteCertificate(String name) {
        final var path = certPath(CMDB_LOCAL_CERT + "/" + FortiGateRestClient.urlEncode(name), null);
        log.info("Deleting old certificate '{}' : DELETE {}", name, path);
        try {
            final var response = client.delete(path);
            if (FortiGateRestClient.isFortiGateSuccess(response)) {
                log.info("SUCCESS: old certificate '{}' deleted", name);
                return true;
            }
            log.warn("Could not delete old certificate '{}' (FortiOS refuses to delete a certificate that is still "
                    + "referenced): {}", name, FortiGateRestClient.describeFailure(response));
            return false;
        } catch (Exception e) {
            log.warn("Could not delete old certificate '{}': {}", name, describe(e));
            return false;
        }
    }

    // ------------------------------------------------------------------ certificate body (best effort)

    /**
     * Name → PEM for every non-CA certificate whose body can be obtained (one download per
     * certificate; cheap and reliable on 7.6). Used by the replacement resolver for thumbprint
     * matching.
     */
    public Map<String, String> knownCertificatePems(List<FortiGateCertificate> certs) {
        final Map<String, String> pems = new LinkedHashMap<>();
        for (FortiGateCertificate c : certs) {
            if (c.getCertificatePem() == null && !c.isCaCertificate()) {
                c.setCertificatePem(tryFetchCertificatePem(c, List.of()));
            }
            if (c.getCertificatePem() != null) {
                pems.put(c.getName(), c.getCertificatePem());
            }
        }
        return pems;
    }

    /**
     * Tries, in order: the PEM already present on the entry (cmdb {@code certificate} attribute);
     * the monitor download endpoint; the single cmdb entry; and, for a certificate bound to the
     * admin GUI or the SSL-VPN portal, a TLS handshake against that listener. Each candidate is
     * accepted only when its serial matches the list entry (when comparable). Returns null when
     * nothing works; the asset is then surfaced with metadata only.
     */
    public String tryFetchCertificatePem(FortiGateCertificate cert, List<CertificateReference> refs) {
        // 1) already known (the cmdb list view returns "certificate": "" on 7.6, but keep the shortcut)
        if (cert.getCertificatePem() != null) {
            log.info("Certificate body for '{}' already known from the cmdb 'certificate' attribute", cert.getName());
            return cert.getCertificatePem();
        }
        // 2) monitor download endpoint - verified on FortiOS 7.6.7 to return every local certificate,
        //    factory-embedded ones included (raw PEM body)
        try {
            final var path = certPath(MON_CERT_DOWNLOAD + "?mkey=" + FortiGateRestClient.urlEncode(cert.getName())
                    + "&type=local-cer", null);
            final var response = client.get(path);
            if (FortiGateRestClient.isSuccess(response)) {
                final var pem = extractPem(response.body());
                if (pem != null && serialMatchesEntry(pem, cert)) {
                    log.info("Certificate body for '{}' fetched via {}", cert.getName(), MON_CERT_DOWNLOAD);
                    return pem;
                }
            }
        } catch (Exception e) {
            log.debug("Download attempt for '{}' failed: {}", cert.getName(), e.getMessage());
        }
        // 2b) the single cmdb entry - unlike the list view it carries the PEM for imported certificates
        try {
            final var entry = firstResult(getQuiet(certPath(CMDB_LOCAL_CERT + "/" + FortiGateRestClient.urlEncode(cert.getName()), null)));
            final var pem = extractPem(entry.path("certificate").asText(""));
            if (pem != null && serialMatchesEntry(pem, cert)) {
                log.info("Certificate body for '{}' read from the cmdb entry's 'certificate' attribute", cert.getName());
                return pem;
            }
        } catch (Exception e) {
            log.debug("cmdb entry read for '{}' failed: {}", cert.getName(), e.getMessage());
        }
        // 3) TLS handshake against a listener that serves this certificate
        for (CertificateReference ref : refs) {
            final InetSocketAddress endpoint = switch (ref.getType()) {
                case ADMIN_HTTPS -> new InetSocketAddress(config.getHost(), config.getPort());
                case SSL_VPN -> new InetSocketAddress(config.getHost(), sslVpnPort());
                default -> null;
            };
            if (endpoint == null) {
                continue;
            }
            try {
                final var served = fetchLeafViaTls(endpoint.getHostString(), endpoint.getPort(), cert.getCommonName());
                if (served != null) {
                    final var pem = FortiGateAutomationPluginHelper.toPem("CERTIFICATE", served.getEncoded());
                    if (serialMatchesEntry(pem, cert)) {
                        log.info("Certificate body for '{}' fetched via TLS from {}", cert.getName(), endpoint);
                        return pem;
                    }
                    log.info("TLS endpoint {} served a different certificate (serial {}) than '{}'", endpoint,
                            CertificateAttributesUtil.serialHex(served), cert.getName());
                }
            } catch (Exception e) {
                log.debug("TLS fetch from {} failed: {}", endpoint, e.getMessage());
            }
        }
        log.info("Certificate body for '{}' is not retrievable from the FortiGate - surfacing metadata only", cert.getName());
        return null;
    }

    private int sslVpnPort() {
        final var settings = firstResult(getQuiet(FortiGateRestClient.withQuery(CMDB_SSL_SETTINGS, config.vdomQuery())));
        return settings.path("port").isNumber() ? settings.path("port").asInt() : 443;
    }

    private static boolean serialMatchesEntry(String pem, FortiGateCertificate cert) {
        try {
            final var x = FortiGateAutomationPluginHelper.parseFirstCertificate(pem);
            if (CertificateAttributesUtil.parseSerial(cert.getSerialNumber()) == null) {
                return true; // nothing comparable; accept on name alone
            }
            return CertificateAttributesUtil.sameSerial(cert.getSerialNumber(), CertificateAttributesUtil.serialHex(x));
        } catch (Exception e) {
            return false;
        }
    }

    /** Extracts the first PEM certificate from a raw or JSON-wrapped body, or null. */
    static String extractPem(String body) {
        if (body == null) {
            return null;
        }
        final var json = FortiGateRestClient.json(body);
        if (!json.isMissingNode()) {
            final var found = findPemInJson(json);
            if (found != null) {
                return found;
            }
        }
        final Matcher m = PEM_CERT.matcher(body.replace("\\n", "\n"));
        return m.find() ? m.group() + "\n" : null;
    }

    private static String findPemInJson(JsonNode node) {
        if (node.isTextual()) {
            final Matcher m = PEM_CERT.matcher(node.asText().replace("\\n", "\n"));
            return m.find() ? m.group() + "\n" : null;
        }
        for (JsonNode child : node) {
            final var found = findPemInJson(child);
            if (found != null) {
                return found;
            }
        }
        return null;
    }

    /** Opens a trust-all TLS connection (with SNI when given) and returns the served leaf certificate. */
    static X509Certificate fetchLeafViaTls(String host, int port, String sni) throws Exception {
        final var ctx = SSLContext.getInstance("TLS");
        ctx.init(null, new TrustManager[] { new X509TrustManager() {
            @Override public void checkClientTrusted(X509Certificate[] c, String a) { }
            @Override public void checkServerTrusted(X509Certificate[] c, String a) { }
            @Override public X509Certificate[] getAcceptedIssuers() { return new X509Certificate[0]; }
        } }, new SecureRandom());
        try (Socket plain = new Socket()) {
            plain.connect(new InetSocketAddress(host, port), 10_000);
            try (SSLSocket socket = (SSLSocket) ctx.getSocketFactory().createSocket(plain, host, port, true)) {
                socket.setSoTimeout(10_000);
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

    // ------------------------------------------------------------------ JSON / path helpers

    /** {@code path} with the certificate-scope query ({@code scope=global} / {@code vdom=…}) and optional extras. */
    private String certPath(String path, String extra) {
        return FortiGateRestClient.withQuery(FortiGateRestClient.withQuery(path, config.certificateScopeQuery()), extra);
    }

    private static String versionOf(JsonNode statusEnvelope) {
        if (statusEnvelope == null || statusEnvelope.isMissingNode()) {
            return null;
        }
        final var v = statusEnvelope.path("version").asText(null);
        final var build = statusEnvelope.path("build").asText(null);
        return v == null ? null : v + (build == null ? "" : " build " + build);
    }

    /** GET that never throws: returns the parsed envelope, or a missing node on any failure. */
    private JsonNode getQuiet(String path) {
        try {
            final var response = client.get(path);
            if (!FortiGateRestClient.isFortiGateSuccess(response)) {
                return FortiGateRestClient.json(null);
            }
            return FortiGateRestClient.json(response.body());
        } catch (Exception e) {
            log.warn("GET {} failed: {}", path, describe(e));
            return FortiGateRestClient.json(null);
        }
    }

    /** {@code results} as an iterable: array → its elements, object → that single object. */
    static Iterable<JsonNode> results(JsonNode root) {
        if (root == null || root.isMissingNode() || root.isNull()) {
            return List.of();
        }
        final var res = root.has("results") ? root.path("results") : root;
        if (res.isArray()) {
            return res;
        }
        if (res.isObject()) {
            return List.of(res);
        }
        return List.of();
    }

    static JsonNode firstResult(JsonNode root) {
        final Iterator<JsonNode> it = results(root).iterator();
        return it.hasNext() ? it.next() : FortiGateRestClient.json(null);
    }

    static String nameOf(JsonNode n) {
        return firstText(n, "name", "q_origin_key", "mkey", "id");
    }

    private static String firstText(JsonNode n, String... fields) {
        for (String f : fields) {
            final var v = n.path(f);
            if (!v.isMissingNode() && !v.isNull()) {
                final var text = v.asText();
                if (!text.isBlank()) {
                    return text;
                }
            }
        }
        return null;
    }

    private static String uniqueName(String requested, Set<String> taken) {
        if (!taken.contains(requested)) {
            return requested;
        }
        for (int i = 2; i < 100; i++) {
            final var suffix = "_" + i;
            var base = requested;
            if (base.length() + suffix.length() > CertificateAttributesUtil.MAX_NAME_LENGTH) {
                base = base.substring(0, CertificateAttributesUtil.MAX_NAME_LENGTH - suffix.length());
            }
            final var candidate = base + suffix;
            if (!taken.contains(candidate)) {
                return candidate;
            }
        }
        return requested + "_" + Long.toHexString(OffsetDateTime.now().toEpochSecond());
    }

    private static void sleepQuietly(long millis) {
        try {
            Thread.sleep(millis);
        } catch (InterruptedException e) {
            Thread.currentThread().interrupt();
        }
    }

    private static String describe(Exception e) {
        final var msg = e.getMessage();
        return Objects.requireNonNullElse(msg, e.getClass().getSimpleName());
    }
}
