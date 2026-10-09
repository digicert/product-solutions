package com.example.automation.adapter;

import java.io.IOException;
import java.net.InetSocketAddress;
import java.net.Socket;
import java.security.SecureRandom;
import java.security.cert.Certificate;
import java.security.cert.X509Certificate;
import java.time.OffsetDateTime;
import java.util.ArrayList;
import java.util.Iterator;
import java.util.LinkedHashMap;
import java.util.LinkedHashSet;
import java.util.List;
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
import com.example.automation.helper.FortiWebAutomationPluginHelper;
import com.example.automation.model.CertificateReference;
import com.example.automation.model.Connection;
import com.example.automation.model.ErrorCode;
import com.example.automation.model.FortiWebCertificate;
import com.example.automation.model.FortiWebConfigurationData;
import com.example.automation.model.FortiWebInstalledCertificate;
import com.example.automation.model.Result;
import com.fasterxml.jackson.databind.JsonNode;

import lombok.extern.slf4j.Slf4j;

/**
 * Drives all certificate-lifecycle operations against a single FortiWeb appliance over its REST API
 * ({@code /api/v2.0}). The endpoints and the rotation strategy are the ones proven by the DigiCert
 * {@code fortiweb-awr.sh} automation (validated on FortiWeb 8.0.5):
 *
 * <pre>
 *   GET    /system/certificate.local                          list local certificates
 *   POST   /system/certificate.local.import_certificate       multipart upload (cert + key)
 *   GET    /cmdb/server-policy/policy[?mkey=P]                server policies → "certificate"
 *   GET    /cmdb/system/certificate.sni                       SNI objects
 *   GET    /cmdb/system/certificate.sni/members?mkey=S        SNI members → "local-cert"
 *   GET    /cmdb/system/certificate.multi-local[?mkey=G]      multi-cert groups → rsa-cert/ecc-cert/dsa-cert
 *   PUT    …?mkey=X[&sub_mkey=Y]   body {"data":{"<field>":"<new cert>"}}   repoint a reference
 *   DELETE /cmdb/system/certificate.local?mkey=OLD            delete an unreferenced certificate
 * </pre>
 *
 * <p><b>Rotate, don't overwrite.</b> FortiWeb cannot overwrite an existing local certificate
 * (importing under an existing name fails as a duplicate) and refuses to delete a certificate while
 * any object references it. So a renewal imports the new certificate under a <em>unique</em> name,
 * repoints every reference to it, and only then deletes the old certificate — guarded by FortiWeb's
 * own {@code can_delete} flag so nothing still in use is ever removed.
 */
@Slf4j
public class FortiWebAdapter {

    static final String CERT_LIST = "/system/certificate.local";
    static final String CERT_IMPORT = "/system/certificate.local.import_certificate";
    static final String CMDB_CERT = "/cmdb/system/certificate.local";
    static final String CMDB_POLICY = "/cmdb/server-policy/policy";
    static final String CMDB_VSERVER = "/cmdb/server-policy/vserver";
    static final String CMDB_VIP = "/cmdb/system/vip";
    static final String CMDB_SERVICE_PREDEFINED = "/cmdb/server-policy/service/predefined";
    static final String CMDB_SERVICE_CUSTOM = "/cmdb/server-policy/service/custom";
    static final String CMDB_SNI = "/cmdb/system/certificate.sni";
    static final String CMDB_MULTI_LOCAL = "/cmdb/system/certificate.multi-local";

    /** Candidate endpoints for reading a certificate body back; tried in order, all best-effort. */
    private static final String[] CERT_DOWNLOAD_CANDIDATES = {
        "/system/certificate.local.download?mkey=%s",
        "/system/certificate.local.download?mkey=%s&type=certificate",
        "/system/certificate.local.view?mkey=%s",
    };

    private static final Pattern IPV4 = Pattern.compile("\\b((?:\\d{1,3}\\.){3}\\d{1,3})\\b");
    private static final Pattern PEM_CERT = Pattern.compile(
            "-----BEGIN CERTIFICATE-----[\\s\\S]+?-----END CERTIFICATE-----");

    private final FortiWebRestClient client;
    private final AdapterConfig config;
    /** Null when SSH is disabled on the connector. */
    private final FortiWebSshClient sshClient;

    public FortiWebAdapter(AdapterConfig config) {
        this.config = config;
        this.client = new FortiWebRestClient(config);
        this.sshClient = config.isSshEnabled() ? new FortiWebSshClient(config) : null;
    }

    /**
     * Certificate name → PEM read from the CLI over SSH ({@code show system certificate local}), or
     * an empty map when SSH is disabled or fails. Never throws: a CLI problem degrades discovery to
     * metadata-only rather than failing it.
     */
    public Map<String, String> fetchCliCertificatePems() {
        if (sshClient == null) {
            log.info("SSH disabled on the connector - certificate bodies will not be read from the CLI");
            return Map.of();
        }
        try {
            return sshClient.fetchCertificatePems();
        } catch (Exception e) {
            log.warn("Could not read certificate bodies from the FortiWeb CLI over SSH ({}:{}): {} - "
                    + "continuing with metadata only", config.getHost(), config.getSshPort(), describe(e));
            return Map.of();
        }
    }

    // ------------------------------------------------------------------ testConnection

    public Result<Connection> testConnection() {
        try {
            final var response = client.get(CERT_LIST);
            if (response.statusCode() == 401 || response.statusCode() == 403) {
                return Result.failure("Unauthorized: FortiWeb rejected the credentials for user '"
                        + config.getUsername() + "' (" + FortiWebRestClient.describeFailure(response) + ")",
                        ErrorCode.UNAUTHORIZED.name());
            }
            if (!FortiWebRestClient.isFortiWebSuccess(response)) {
                return Result.failure("FortiWeb API error listing certificates: "
                        + FortiWebRestClient.describeFailure(response), ErrorCode.FORTIWEB_API_ERROR.name());
            }
            final var certs = parseCertificates(response.body());
            log.info("testConnection OK: {} local certificate(s) on {}", certs.size(), config.getHost());
            return Result.success(new Connection(true));
        } catch (Exception e) {
            log.error("Error during testConnection", e);
            return Result.failure(describe(e), ErrorCode.INTERNAL_ERROR.name());
        }
    }

    // ------------------------------------------------------------------ refreshConfiguration

    /**
     * Builds the inventory: every local certificate plus where it is referenced. Every certificate
     * is surfaced — including expired, self-signed and unreferenced ones, which are exactly the
     * certificates an operator wants to replace. The certificate body is fetched best-effort (see
     * {@link #tryFetchCertificatePem}); FortiWeb's list does not include it.
     */
    public Result<FortiWebConfigurationData> getConfigurationData() {
        try {
            final var data = new FortiWebConfigurationData();
            data.setHost(config.getHost());
            data.setPort(config.getPort());

            final var certs = listCertificates();
            final var references = collectReferences();
            data.setReferences(references);
            final var cliPems = fetchCliCertificatePems();

            for (FortiWebCertificate cert : certs) {
                final var refs = references.getOrDefault(cert.getName(), List.of());
                cert.setCertificatePem(tryFetchCertificatePem(cert, refs, cliPems));
                log.info("Discovered certificate: name={}, cn={}, selfSigned={}, pkey_type={}, validTo={}, "
                        + "q_ref={}, can_delete={}, references={}, pem={}",
                        cert.getName(), cert.getCommonName(), cert.isSelfSigned(), cert.getPkeyType(),
                        cert.getValidTo(), cert.getRefCount(), cert.getCanDelete(), refs,
                        cert.getCertificatePem() != null ? "yes" : "no");
            }
            data.setCertificates(certs);
            log.info("RefreshConfiguration discovered {} certificate(s) on {}", certs.size(), config.getHost());
            return Result.success(data);
        } catch (Exception e) {
            log.error("Error during getConfigurationData", e);
            return Result.failure(describe(e), ErrorCode.FORTIWEB_API_ERROR.name());
        }
    }

    // ------------------------------------------------------------------ installCertificate

    /**
     * Imports the renewed certificate under {@code requestedName} (made unique if taken), repoints
     * every reference of each {@code oldCertNames} entry to it, and deletes the old certificates
     * once FortiWeb reports them as unreferenced (unless {@code keepReplaced}).
     *
     * <p>Idempotent on retry: if {@code requestedName} already exists and carries the same serial as
     * {@code leaf}, the import is skipped and only the rotation is (re)run.
     *
     * @param certFilePem content of the certificate file to upload (leaf, optionally followed by ICAs)
     * @param keyPem      unencrypted PKCS#8 private key matching the leaf
     * @param leaf        parsed end-entity certificate (for serial / algorithm checks)
     */
    public Result<FortiWebInstalledCertificate> installCertificate(String requestedName, String certFilePem,
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
                log.warn("Certificate '{}' with serial {} already exists on FortiWeb - skipping import, "
                        + "continuing with rotation", requestedName, leafSerial);
            } else {
                newName = uniqueName(requestedName, beforeNames);
                if (!newName.equals(requestedName)) {
                    log.warn("Name '{}' is already taken by a different certificate; importing as '{}'",
                            requestedName, newName);
                }
                log.info("Existing certificates on FortiWeb: {}", beforeNames);
                log.info("Importing certificate as '{}' (serial {})", newName, leafSerial);

                final var response = client.postMultipart(CERT_IMPORT,
                        FortiWebRestClient.fields("type", "certificate", "hsm", "undefined", "password", "undefined"),
                        Map.of("certificateFile", FortiWebRestClient.FilePart.pem(newName + ".crt", certFilePem),
                               "keyFile", FortiWebRestClient.FilePart.pem(newName + ".key", keyPem)));
                if (!FortiWebRestClient.isFortiWebSuccess(response)) {
                    return Result.failure("FortiWeb rejected the certificate import: "
                            + FortiWebRestClient.describeFailure(response)
                            + (response.statusCode() == 400
                                    ? " (a 400 usually means the certificate/key are invalid, mismatched, or the name already exists)"
                                    : ""),
                            ErrorCode.CERTIFICATE_IMPORT_ERROR.name());
                }
                log.info("Import accepted: {}", FortiWebRestClient.describeFailure(response));

                // --- 2. confirm the name FortiWeb actually assigned ----------------------------
                sleepQuietly(1000);
                final var after = listCertificates();
                final var added = new TreeSet<String>();
                after.forEach(c -> { if (!beforeNames.contains(c.getName())) { added.add(c.getName()); } });
                if (added.contains(newName)) {
                    log.info("FortiWeb stored the new certificate as '{}'", newName);
                } else if (added.size() == 1) {
                    newName = added.first();
                    log.warn("FortiWeb stored the new certificate under '{}' rather than '{}'", newName, requestedName);
                } else {
                    return Result.failure("Import returned success but the new certificate '" + newName
                            + "' did not appear in the FortiWeb certificate list (new names seen: " + added + ")",
                            ErrorCode.CERTIFICATE_IMPORT_ERROR.name());
                }
            }

            final var installed = new FortiWebInstalledCertificate();
            installed.setCertificateName(newName);
            installed.setSerialNumber(leafSerial);

            final var newEntry = findCertificate(newName).orElse(null);
            if (newEntry != null && newEntry.getSerialNumber() != null
                    && CertificateAttributesUtil.parseSerial(newEntry.getSerialNumber()) != null
                    && !CertificateAttributesUtil.sameSerial(newEntry.getSerialNumber(), leafSerial)) {
                log.warn("Serial reported by FortiWeb for '{}' ({}) differs from the uploaded leaf ({}); "
                        + "continuing on the strength of the list diff", newName, newEntry.getSerialNumber(), leafSerial);
            }
            final Integer newPkeyType = newEntry == null ? null : newEntry.getPkeyType();

            // --- 3. rotate references off each previous certificate --------------------------
            final List<String> failures = new ArrayList<>();
            int repointed = 0;
            for (String oldName : new LinkedHashSet<>(oldCertNames)) {
                if (oldName == null || oldName.isBlank() || oldName.equals(newName)) {
                    continue;
                }
                final var oldEntry = findCertificate(oldName).orElse(null);
                if (oldEntry == null) {
                    log.info("Previous certificate '{}' is not present on FortiWeb - nothing to rotate", oldName);
                    continue;
                }
                log.info("Processing previous certificate '{}' (pkey_type={}, q_ref={}, can_delete={})",
                        oldName, oldEntry.getPkeyType(), oldEntry.getRefCount(), oldEntry.getCanDelete());

                final var refs = collectReferences().getOrDefault(oldName, List.of());
                if (refs.isEmpty()) {
                    log.info("Certificate '{}' is not referenced by any policy, SNI member or multi-cert group", oldName);
                }
                boolean allOk = true;
                for (CertificateReference ref : refs) {
                    if (ref.getType() == CertificateReference.Type.MULTI_LOCAL && newPkeyType != null
                            && oldEntry.getPkeyType() != null && !newPkeyType.equals(oldEntry.getPkeyType())) {
                        // rsa-cert / ecc-cert slots are algorithm-specific: never put an RSA cert in
                        // the ECC slot or vice versa.
                        log.error("Cannot repoint {}: new certificate key type ({}) differs from the old one ({})",
                                ref, newPkeyType, oldEntry.getPkeyType());
                        failures.add(ref + ": key algorithm differs");
                        allOk = false;
                        continue;
                    }
                    if (repoint(ref, newName)) {
                        repointed++;
                    } else {
                        failures.add(ref.toString());
                        allOk = false;
                    }
                }
                if (!refs.isEmpty()) {
                    log.info("Waiting 2 seconds for FortiWeb to apply the new binding(s)...");
                    sleepQuietly(2000);
                }

                // --- 4. delete the old certificate once FortiWeb agrees it is unreferenced ------
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
                final var recheck = findCertificate(oldName).orElse(null);
                if (recheck == null) {
                    log.info("'{}' no longer present - nothing to delete", oldName);
                    continue;
                }
                if (!recheck.isUnreferenced()) {
                    log.warn("SKIP delete: '{}' still reports can_delete={} / q_ref={} (an object this plugin does "
                            + "not scan still references it) - leaving it in place for manual review",
                            oldName, recheck.getCanDelete(), recheck.getRefCount());
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
     * Confirms {@code name} is present on FortiWeb (status OK) and, when {@code expectedSerialHex}
     * is known and FortiWeb reports a parseable serial, that the serials agree. Returns the
     * FortiWeb list entry; the PEM is filled from {@link #tryFetchCertificatePem} when possible.
     */
    public Result<FortiWebCertificate> validateCertificate(String name, String expectedSerialHex) {
        try {
            final var entry = findCertificate(name).orElse(null);
            if (entry == null) {
                return Result.failure("Certificate '" + name + "' is not present on FortiWeb " + config.getHost(),
                        ErrorCode.CERTIFICATE_VALIDATION_ERROR.name());
            }
            if (entry.getStatus() != null && !"OK".equalsIgnoreCase(entry.getStatus().trim())) {
                return Result.failure("Certificate '" + name + "' has status '" + entry.getStatus() + "' on FortiWeb",
                        ErrorCode.CERTIFICATE_VALIDATION_ERROR.name());
            }
            if (expectedSerialHex != null && !expectedSerialHex.isBlank()
                    && CertificateAttributesUtil.parseSerial(entry.getSerialNumber()) != null
                    && !CertificateAttributesUtil.sameSerial(entry.getSerialNumber(), expectedSerialHex)) {
                return Result.failure("Certificate '" + name + "' on FortiWeb has serial " + entry.getSerialNumber()
                        + " but TLM expected " + expectedSerialHex, ErrorCode.CERTIFICATE_VALIDATION_ERROR.name());
            }
            final var refs = collectReferences().getOrDefault(name, List.of());
            entry.setCertificatePem(tryFetchCertificatePem(entry, refs, fetchCliCertificatePems()));
            log.info("Validated '{}': status={}, serial={}, validTo={}, references={}", name, entry.getStatus(),
                    entry.getSerialNumber(), entry.getValidTo(), refs);
            return Result.success(entry);
        } catch (Exception e) {
            log.error("Error during validateCertificate for {}", name, e);
            return Result.failure(describe(e), ErrorCode.INTERNAL_ERROR.name());
        }
    }

    // ------------------------------------------------------------------ certificate list

    public List<FortiWebCertificate> listCertificates() throws IOException, InterruptedException {
        final var response = client.get(CERT_LIST);
        if (!FortiWebRestClient.isFortiWebSuccess(response)) {
            throw new IOException("Listing FortiWeb certificates failed: " + FortiWebRestClient.describeFailure(response));
        }
        return parseCertificates(response.body());
    }

    public Optional<FortiWebCertificate> findCertificate(String name) throws IOException, InterruptedException {
        return listCertificates().stream().filter(c -> name.equals(c.getName())).findFirst();
    }

    static List<FortiWebCertificate> parseCertificates(String body) {
        final List<FortiWebCertificate> certs = new ArrayList<>();
        for (JsonNode n : results(FortiWebRestClient.json(body))) {
            final var name = nameOf(n);
            if (name == null) {
                continue;
            }
            final var c = new FortiWebCertificate();
            c.setName(name);
            c.setRefCount(n.path("q_ref").asInt(0));
            c.setPkeyType(n.hasNonNull("pkey_type") ? n.path("pkey_type").asInt() : null);
            c.setCanDelete(n.hasNonNull("can_delete") ? n.path("can_delete").asBoolean() : null);
            c.setStatus(n.path("status").asText(null));
            c.setIssuer(n.path("issuer").asText(null));
            c.setSubject(n.path("subject").asText(null));
            c.setValidFrom(n.path("validFrom").asText(null));
            c.setValidTo(n.path("validTo").asText(null));
            c.setSerialNumber(n.path("serialNumber").asText(null));
            certs.add(c);
        }
        return certs;
    }

    // ------------------------------------------------------------------ references

    /**
     * Scans server policies, SNI members and multi-cert groups and returns, per local certificate
     * name, every place it is referenced. Objects that cannot be read are logged and skipped, so a
     * single odd object never aborts discovery.
     */
    public Map<String, List<CertificateReference>> collectReferences() {
        final Map<String, List<CertificateReference>> refs = new LinkedHashMap<>();

        // (1) server policies → "certificate"
        for (String policy : listNames(CMDB_POLICY)) {
            final var node = firstResult(getQuiet(CMDB_POLICY + "?mkey=" + FortiWebRestClient.urlEncode(policy)));
            final var cert = node.path("certificate").asText("");
            log.info("Policy '{}' certificate='{}' certificate-type='{}' sni-certificate='{}' multi-certificate='{}'",
                    policy, cert, node.path("certificate-type").asText(""), node.path("sni-certificate").asText(""),
                    node.path("multi-certificate").asText(""));
            if (!cert.isBlank()) {
                refs.computeIfAbsent(cert, k -> new ArrayList<>()).add(
                        new CertificateReference(CertificateReference.Type.SERVER_POLICY, policy, null, cert));
            }
        }

        // (2) SNI objects → members → "local-cert"
        for (String sni : listNames(CMDB_SNI)) {
            for (JsonNode member : results(getQuiet(CMDB_SNI + "/members?mkey=" + FortiWebRestClient.urlEncode(sni)))) {
                final var cert = member.path("local-cert").asText("");
                final var id = firstText(member, "id", "_id", "mkey");
                log.info("SNI '{}' member '{}' domain='{}' local-cert='{}' multi-local-cert-group='{}'", sni, id,
                        member.path("domain").asText(""), cert, member.path("multi-local-cert-group").asText(""));
                if (!cert.isBlank() && id != null) {
                    refs.computeIfAbsent(cert, k -> new ArrayList<>()).add(
                            new CertificateReference(CertificateReference.Type.SNI_MEMBER, sni, id, cert));
                }
            }
        }

        // (3) multi-cert groups → rsa-cert / ecc-cert / dsa-cert
        for (String group : listNames(CMDB_MULTI_LOCAL)) {
            final var node = firstResult(getQuiet(CMDB_MULTI_LOCAL + "?mkey=" + FortiWebRestClient.urlEncode(group)));
            for (String field : new String[] { "rsa-cert", "ecc-cert", "dsa-cert" }) {
                final var cert = node.path(field).asText("");
                if (!cert.isBlank()) {
                    log.info("Multi-cert group '{}' {}='{}'", group, field, cert);
                    refs.computeIfAbsent(cert, k -> new ArrayList<>()).add(
                            new CertificateReference(CertificateReference.Type.MULTI_LOCAL, group, field, cert));
                }
            }
        }
        return refs;
    }

    /** Repoints one reference to {@code newCert}; true on success. */
    boolean repoint(CertificateReference ref, String newCert) {
        final String path;
        final String field;
        switch (ref.getType()) {
            case SERVER_POLICY -> {
                path = CMDB_POLICY + "?mkey=" + FortiWebRestClient.urlEncode(ref.getObjectName());
                field = "certificate";
            }
            case SNI_MEMBER -> {
                path = CMDB_SNI + "/members?mkey=" + FortiWebRestClient.urlEncode(ref.getObjectName())
                        + "&sub_mkey=" + FortiWebRestClient.urlEncode(ref.getSubKey());
                field = "local-cert";
            }
            case MULTI_LOCAL -> {
                path = CMDB_MULTI_LOCAL + "?mkey=" + FortiWebRestClient.urlEncode(ref.getObjectName());
                field = ref.getSubKey();
            }
            default -> throw new IllegalStateException("Unknown reference type " + ref.getType());
        }
        final var body = "{\"data\":{\"" + field + "\":\"" + newCert + "\"}}";
        log.info("Repointing {} from '{}' to '{}' : PUT {} body={}", ref, ref.getCertificateName(), newCert, path, body);
        try {
            final var response = client.putJson(path, body);
            if (FortiWebRestClient.isFortiWebSuccess(response)) {
                log.info("{} successfully repointed to '{}'", ref, newCert);
                return true;
            }
            log.error("Failed to repoint {}: {}", ref, FortiWebRestClient.describeFailure(response));
            return false;
        } catch (Exception e) {
            log.error("Failed to repoint {}: {}", ref, describe(e));
            return false;
        }
    }

    boolean deleteCertificate(String name) {
        final var path = CMDB_CERT + "?mkey=" + FortiWebRestClient.urlEncode(name);
        log.info("Deleting old certificate '{}' : DELETE {}", name, path);
        try {
            final var response = client.delete(path);
            if (FortiWebRestClient.isFortiWebSuccess(response)) {
                log.info("SUCCESS: old certificate '{}' deleted", name);
                return true;
            }
            log.warn("Could not delete old certificate '{}': {}", name, FortiWebRestClient.describeFailure(response));
            return false;
        } catch (Exception e) {
            log.warn("Could not delete old certificate '{}': {}", name, describe(e));
            return false;
        }
    }

    // ------------------------------------------------------------------ certificate body (best effort)

    /**
     * FortiWeb's certificate list carries metadata only, never the PEM. This tries, in order:
     * <ol>
     *   <li>the body read from the CLI over SSH ({@code show system certificate local}) — the
     *       reliable path on 8.0.5 — accepted when, if comparable, its serial matches the list entry;</li>
     *   <li>a download/view endpoint on the management API (on 8.0.5 these refuse imported
     *       certificates, kept for other firmware);</li>
     *   <li>for a certificate bound to a server policy, a TLS handshake against the policy's
     *       virtual IP / HTTPS port (SNI = the certificate's CN) — again accepted only when the
     *       served leaf's serial matches.</li>
     * </ol>
     * Returns null when nothing works; the asset is then surfaced with metadata only.
     */
    public String tryFetchCertificatePem(FortiWebCertificate cert, List<CertificateReference> refs,
                                         Map<String, String> cliPems) {
        // 1) CLI over SSH
        final var cliPem = cliPems == null ? null : cliPems.get(cert.getName());
        if (cliPem != null) {
            if (serialMatchesEntry(cliPem, cert)) {
                log.info("Certificate body for '{}' read from the CLI over SSH", cert.getName());
                return cliPem;
            }
            log.warn("CLI returned a certificate for '{}' whose serial does not match the API list entry ({}); ignoring it",
                    cert.getName(), cert.getSerialNumber());
        }
        // 2) management API
        for (String template : CERT_DOWNLOAD_CANDIDATES) {
            final var path = String.format(template, FortiWebRestClient.urlEncode(cert.getName()));
            try {
                final var response = client.get(path);
                if (!FortiWebRestClient.isSuccess(response)) {
                    continue;
                }
                final var pem = extractPem(response.body());
                if (pem != null && serialMatchesEntry(pem, cert)) {
                    log.info("Fetched certificate body for '{}' via {}", cert.getName(), path);
                    return pem;
                }
            } catch (Exception e) {
                log.debug("Download attempt {} failed: {}", path, e.getMessage());
            }
        }
        // 3) TLS handshake against a bound server policy's VIP
        for (CertificateReference ref : refs) {
            if (ref.getType() != CertificateReference.Type.SERVER_POLICY) {
                continue;
            }
            final var endpoint = resolvePolicyEndpoint(ref.getObjectName());
            if (endpoint == null) {
                continue;
            }
            try {
                final var served = fetchLeafViaTls(endpoint.getHostString(), endpoint.getPort(), cert.getCommonName());
                if (served != null) {
                    final var pem = FortiWebAutomationPluginHelper.toPem("CERTIFICATE", served.getEncoded());
                    if (serialMatchesEntry(pem, cert)) {
                        log.info("Fetched certificate body for '{}' via TLS from {}", cert.getName(), endpoint);
                        return pem;
                    }
                    log.info("TLS endpoint {} served a different certificate (serial {}) than '{}'", endpoint,
                            CertificateAttributesUtil.serialHex(served), cert.getName());
                }
            } catch (Exception e) {
                log.debug("TLS fetch from {} failed: {}", endpoint, e.getMessage());
            }
        }
        log.info("Certificate body for '{}' is not retrievable from FortiWeb - surfacing metadata only", cert.getName());
        return null;
    }

    private static boolean serialMatchesEntry(String pem, FortiWebCertificate cert) {
        try {
            final var x = FortiWebAutomationPluginHelper.parseFirstCertificate(pem);
            if (CertificateAttributesUtil.parseSerial(cert.getSerialNumber()) == null) {
                return true; // FortiWeb printed nothing comparable; accept on name alone
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
        final var json = FortiWebRestClient.json(body);
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
            final Matcher m = PEM_CERT.matcher(node.asText());
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

    /**
     * Best-effort resolution of a server policy's data-plane endpoint: policy → {@code vserver} →
     * VIP list → {@code system/vip} address, plus the policy's {@code https-service} port. Every hop
     * is tolerant of missing fields and returns null instead of failing.
     */
    InetSocketAddress resolvePolicyEndpoint(String policyName) {
        try {
            final var policy = firstResult(getQuiet(CMDB_POLICY + "?mkey=" + FortiWebRestClient.urlEncode(policyName)));
            final var vserverName = policy.path("vserver").asText("");
            if (vserverName.isBlank()) {
                return null;
            }
            String ip = null;
            final var vserver = firstResult(getQuiet(CMDB_VSERVER + "?mkey=" + FortiWebRestClient.urlEncode(vserverName)));
            ip = firstIpv4(vserver.path("vip").asText(""), vserver.path("ip").asText(""), vserver.path("address").asText(""));
            if (ip == null) {
                for (JsonNode member : results(getQuiet(CMDB_VSERVER + "/vip-list?mkey=" + FortiWebRestClient.urlEncode(vserverName)))) {
                    final var vipName = member.path("vip").asText("");
                    if (vipName.isBlank()) {
                        continue;
                    }
                    final var vip = firstResult(getQuiet(CMDB_VIP + "?mkey=" + FortiWebRestClient.urlEncode(vipName)));
                    ip = firstIpv4(vip.path("vip").asText(""), vip.path("ip").asText(""), vipName);
                    if (ip != null) {
                        break;
                    }
                }
            }
            if (ip == null) {
                return null;
            }
            int port = 443;
            final var service = policy.path("https-service").asText("");
            if (!service.isBlank() && !"HTTPS".equalsIgnoreCase(service)) {
                for (String base : new String[] { CMDB_SERVICE_PREDEFINED, CMDB_SERVICE_CUSTOM }) {
                    final var svc = firstResult(getQuiet(base + "?mkey=" + FortiWebRestClient.urlEncode(service)));
                    if (svc.path("port").isNumber() || svc.path("port").asText("").matches("\\d+")) {
                        port = svc.path("port").asInt(443);
                        break;
                    }
                }
            }
            log.info("Policy '{}' data endpoint resolved to {}:{} (vserver '{}')", policyName, ip, port, vserverName);
            return new InetSocketAddress(ip, port);
        } catch (Exception e) {
            log.debug("Could not resolve endpoint of policy '{}': {}", policyName, e.getMessage());
            return null;
        }
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

    // ------------------------------------------------------------------ JSON helpers

    /** Names ({@code name} / {@code mkey} / {@code _id}) of every entry of a CMDB list endpoint. */
    private List<String> listNames(String path) {
        final List<String> names = new ArrayList<>();
        for (JsonNode n : results(getQuiet(path))) {
            final var name = nameOf(n);
            if (name != null && !names.contains(name)) {
                names.add(name);
            }
        }
        return names;
    }

    /** GET that never throws: returns the parsed body, or a missing node on any failure. */
    private JsonNode getQuiet(String path) {
        try {
            final var response = client.get(path);
            if (!FortiWebRestClient.isSuccess(response)) {
                return FortiWebRestClient.json(null);
            }
            return FortiWebRestClient.json(response.body());
        } catch (Exception e) {
            log.warn("GET {} failed: {}", path, describe(e));
            return FortiWebRestClient.json(null);
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
        return it.hasNext() ? it.next() : FortiWebRestClient.json(null);
    }

    static String nameOf(JsonNode n) {
        return firstText(n, "name", "mkey", "_id");
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

    private static String firstIpv4(String... candidates) {
        for (String c : candidates) {
            if (c == null) {
                continue;
            }
            final Matcher m = IPV4.matcher(c);
            if (m.find()) {
                return m.group(1);
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
