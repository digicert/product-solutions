package com.example.automation.adapter;

import java.io.ByteArrayInputStream;
import java.nio.charset.StandardCharsets;
import java.security.cert.CertificateFactory;
import java.security.cert.X509Certificate;
import java.time.OffsetDateTime;
import java.util.ArrayList;
import java.util.Base64;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.Optional;
import java.util.concurrent.ConcurrentHashMap;

import com.azure.core.exception.AzureException;
import com.azure.core.exception.HttpResponseException;
import com.azure.core.util.polling.LongRunningOperationStatus;
import com.azure.core.util.polling.SyncPoller;
import com.azure.security.keyvault.certificates.CertificateClient;
import com.azure.security.keyvault.certificates.CertificateClientBuilder;
import com.azure.security.keyvault.certificates.models.CertificateKeyCurveName;
import com.azure.security.keyvault.certificates.models.CertificateKeyType;
import com.azure.security.keyvault.certificates.models.CertificateOperation;
import com.azure.security.keyvault.certificates.models.CertificatePolicy;
import com.azure.security.keyvault.certificates.models.CertificateProperties;
import com.azure.security.keyvault.certificates.models.KeyVaultCertificateWithPolicy;
import com.azure.security.keyvault.certificates.models.MergeCertificateOptions;
import com.azure.security.keyvault.certificates.models.SubjectAlternativeNames;
import com.example.automation.helper.CertificateAttributesUtil;
import com.example.automation.model.AzureKeyVaultConfigurationData;
import com.example.automation.model.AzureKeyVaultConfigurationData.CertificateAsset;
import com.example.automation.model.AzureKeyVaultConfigurationData.SubscriptionInfo;
import com.example.automation.model.AzureKeyVaultGeneratedCsr;
import com.example.automation.model.AzureKeyVaultInstalledCertificate;
import com.example.automation.model.Connection;
import com.example.automation.model.ErrorCode;
import com.example.automation.model.KeyVaultInfo;
import com.example.automation.model.Result;

import lombok.extern.slf4j.Slf4j;

/**
 * Drives all certificate-lifecycle operations against <em>every</em> Azure Key Vault in one
 * subscription. Vaults are enumerated through {@link AzureResourceManagerClient} (control plane);
 * certificates are read and written through one Azure Certificates SDK client per vault (data
 * plane), built lazily and cached.
 *
 * <p>The private key never leaves Azure: {@code generateCsr} creates the certificate with the
 * {@code Unknown} issuer (Azure generates the key and returns a CSR), and {@code installCertificate}
 * merges the CA-signed certificate back in. Because Azure Key Vault treats a create against an
 * existing certificate <em>name</em> as a new version, renewing a discovered certificate is simply a
 * matter of reusing its name in its own vault.
 */
@Slf4j
public class AzureKeyVaultSubscriptionAdapter {

    private static final String UNKNOWN_ISSUER = "Unknown";

    /** Default public-cloud vault DNS suffix, used only when ARM cannot resolve a vault by name. */
    private static final String DEFAULT_VAULT_DNS_SUFFIX = ".vault.azure.net";

    private final AdapterConfig config;
    private final AzureCredentialsProvider credentialsProvider;
    private final AzureResourceManagerClient armClient;
    private final Map<String, CertificateClient> clients = new ConcurrentHashMap<>();

    /** Vault list from the most recent ARM enumeration in this process, keyed by lower-case name. */
    private volatile Map<String, KeyVaultInfo> vaultCache;

    public AzureKeyVaultSubscriptionAdapter(AdapterConfig config) {
        this.config = config;
        this.credentialsProvider = new AzureCredentialsProvider(config);
        this.armClient = new AzureResourceManagerClient(config,
                credentialsProvider.getClientSecretCredential());
    }

    // ------------------------------------------------------------------ testConnection

    /**
     * Proves the control-plane permission (ARM vault listing) and the data-plane permission on the
     * discovered vaults (first page of certificates). ARM lists every vault the Reader role can see,
     * including vaults whose certificates are owned by <em>other</em> service principals; those are
     * expected in a shared subscription, so they are logged and skipped rather than failing the
     * test. The test fails only when ARM itself fails or when no listed vault is readable at all.
     */
    public Result<Connection> testConnection() {
        final List<KeyVaultInfo> vaults;
        try {
            vaults = refreshVaultCache();
        } catch (Exception e) {
            return armFailure("listing Key Vaults in subscription " + config.getSubscriptionId(), e);
        }
        if (vaults.isEmpty()) {
            log.warn("No Key Vault matched in subscription {} — check the subscription id, the Reader "
                    + "role and the connector filters", config.getSubscriptionId());
            return Result.success(new Connection(true));
        }
        final List<String> unreadable = new ArrayList<>();
        for (KeyVaultInfo vault : vaults) {
            try {
                getCertificateClient(vault).listPropertiesOfCertificates().iterator().hasNext();
            } catch (Exception e) {
                log.warn("Vault {} is listed by ARM but its certificates cannot be read: {}",
                        vault.getName(), e.getMessage());
                unreadable.add(vault.getName() + " (" + shortMessage(e) + ")");
            }
        }
        if (unreadable.size() == vaults.size()) {
            return Result.failure("ARM lists " + vaults.size() + " vault(s) in subscription "
                    + config.getSubscriptionId() + " but none can be read on the data plane — grant "
                    + "this service principal certificate get/list/create (e.g. Key Vault Certificates "
                    + "Officer) on the vaults it should manage: " + String.join("; ", unreadable),
                    ErrorCode.UNAUTHORIZED.name());
        }
        if (!unreadable.isEmpty()) {
            log.warn("TestConnection: {} of {} vault(s) are not readable by this service principal and "
                    + "will be skipped by discovery (use the resource-group / name / tag filters to "
                    + "hide them): {}", unreadable.size(), vaults.size(), String.join("; ", unreadable));
        }
        log.info("TestConnection OK: {} of {} vault(s) readable in subscription {}",
                vaults.size() - unreadable.size(), vaults.size(), config.getSubscriptionId());
        return Result.success(new Connection(true));
    }

    // ------------------------------------------------------------------ refreshConfiguration

    /**
     * Builds the inventory of certificate assets held in every vault of the subscription that this
     * service principal can read.
     *
     * <p>By default every certificate object is surfaced — including expired, disabled and
     * self-signed ones. A vault that cannot be read (typically one whose certificates belong to a
     * different service principal) is skipped and reported in {@code unreachableVaults}, so it never
     * hides the others and never fails the refresh.
     */
    public Result<AzureKeyVaultConfigurationData> getConfigurationData(
            boolean excludeExpired, boolean excludeDisabled) {
        final List<KeyVaultInfo> vaults;
        try {
            vaults = refreshVaultCache();
        } catch (Exception e) {
            return armFailure("listing Key Vaults in subscription " + config.getSubscriptionId(), e);
        }
        try {
            final var data = new AzureKeyVaultConfigurationData();
            final var sub = new SubscriptionInfo();
            sub.setSubscriptionId(config.getSubscriptionId());
            sub.setDisplayName(armClient.subscriptionDisplayName().orElse(config.getSubscriptionId()));
            data.setSubscriptionInfo(sub);
            data.setVaults(vaults);

            final List<CertificateAsset> assets = new ArrayList<>();
            int skippedExpired = 0;
            int skippedDisabled = 0;
            for (KeyVaultInfo vault : vaults) {
                try {
                    final var client = getCertificateClient(vault);
                    int found = 0;
                    for (CertificateProperties props : client.listPropertiesOfCertificates()) {
                        if (excludeDisabled && !Boolean.TRUE.equals(props.isEnabled())) {
                            skippedDisabled++;
                            log.info("Excluding disabled certificate {}/{}", vault.getName(), props.getName());
                            continue;
                        }
                        if (excludeExpired && isExpired(props.getExpiresOn())) {
                            skippedExpired++;
                            log.info("Excluding expired certificate {}/{} (expired {})",
                                    vault.getName(), props.getName(), props.getExpiresOn());
                            continue;
                        }
                        assets.add(toAsset(vault, client, props));
                        found++;
                    }
                    log.info("Vault {}: {} certificate(s) discovered", vault.getName(), found);
                } catch (Exception e) {
                    log.warn("Vault {} could not be read and is skipped from discovery: {}",
                            vault.getName(), e.getMessage());
                    data.getUnreachableVaults().add(vault.getName());
                }
            }
            data.setCertificates(assets);
            log.info("RefreshConfiguration discovered {} certificate(s) across {} vault(s) in "
                    + "subscription {} (excluded {} expired, {} disabled; {} vault(s) unreadable)",
                    assets.size(), vaults.size() - data.getUnreachableVaults().size(),
                    config.getSubscriptionId(), skippedExpired, skippedDisabled,
                    data.getUnreachableVaults().size());
            return Result.success(data);
        } catch (Exception e) {
            log.error("Error during getConfigurationData", e);
            return Result.failure(e.getMessage(), classify(e));
        }
    }

    private CertificateAsset toAsset(KeyVaultInfo vault, CertificateClient client,
                                     CertificateProperties props) {
        final var asset = new CertificateAsset();
        asset.setVaultName(vault.getName());
        asset.setVaultUri(vault.getVaultUri());
        asset.setName(props.getName());
        asset.setEnabled(Boolean.TRUE.equals(props.isEnabled()));
        asset.setExpiresOn(props.getExpiresOn() == null ? null : props.getExpiresOn().toString());
        asset.setThumbprint(props.getX509Thumbprint() == null
                ? null : bytesToHexUpper(props.getX509Thumbprint()));
        // Best-effort: Azure blocks reading a DISABLED certificate's material; keep the asset
        // visible by name/thumbprint so an operator can still act on it.
        try {
            final var cert = client.getCertificate(props.getName());
            final byte[] der = cert.getCer();
            asset.setCertificate(derToPem(der, "CERTIFICATE"));
            final X509Certificate x = parseX509(der);
            if (x != null) {
                asset.setSubject(x.getSubjectX500Principal().getName());
                asset.setSelfSigned(x.getSubjectX500Principal().equals(x.getIssuerX500Principal()));
            }
        } catch (Exception e) {
            log.warn("Certificate {}/{} is present but its material could not be read (it may be "
                    + "disabled); surfacing it as a name-only asset. Reason: {}",
                    vault.getName(), props.getName(), e.getMessage());
        }
        log.info("Discovered certificate: vault={}, name={}, enabled={}, selfSigned={}, expiresOn={}, "
                + "thumbprint={}", asset.getVaultName(), asset.getName(), asset.isEnabled(),
                asset.isSelfSigned(), asset.getExpiresOn(), asset.getThumbprint());
        return asset;
    }

    // ------------------------------------------------------------------ vault resolution

    /**
     * Resolves a vault by short name. Uses the cached ARM listing, refreshing it once on a miss
     * (the vault may be new, or this may be a fresh process). As a last resort, when ARM is
     * unavailable, falls back to the public-cloud DNS form {@code https://<name>.vault.azure.net/}.
     */
    public Result<KeyVaultInfo> resolveVault(String vaultName) {
        if (vaultName == null || vaultName.isBlank()) {
            return Result.failure("A vault name is required", ErrorCode.VAULT_NOT_FOUND.name());
        }
        final var key = vaultName.trim().toLowerCase(Locale.ROOT);
        var cache = vaultCache;
        if (cache == null || !cache.containsKey(key)) {
            try {
                refreshVaultCache();
                cache = vaultCache;
            } catch (Exception e) {
                log.warn("ARM vault listing failed while resolving vault {} ({}); assuming {}{}",
                        vaultName, e.getMessage(), key, DEFAULT_VAULT_DNS_SUFFIX);
                final var assumed = new KeyVaultInfo();
                assumed.setName(vaultName.trim());
                assumed.setVaultUri("https://" + key + DEFAULT_VAULT_DNS_SUFFIX + "/");
                return Result.success(assumed);
            }
        }
        final var vault = cache.get(key);
        if (vault == null) {
            return Result.failure("Key Vault '" + vaultName + "' was not found in subscription "
                    + config.getSubscriptionId() + " (or is excluded by the connector filters)",
                    ErrorCode.VAULT_NOT_FOUND.name());
        }
        return Result.success(vault);
    }

    /**
     * Finds the vault(s) holding a certificate of the given name. Used only when a request carries
     * a certificate name without its vault; an unambiguous single hit is returned, anything else is
     * an error so the plugin never renews the wrong object.
     */
    public Result<KeyVaultInfo> findVaultHoldingCertificate(String certName) {
        final List<KeyVaultInfo> vaults;
        try {
            vaults = refreshVaultCache();
        } catch (Exception e) {
            return armFailure("listing Key Vaults to locate certificate " + certName, e);
        }
        final List<KeyVaultInfo> hits = new ArrayList<>();
        for (KeyVaultInfo vault : vaults) {
            try {
                getCertificateClient(vault).getCertificate(certName);
                hits.add(vault);
            } catch (HttpResponseException e) {
                final int status = e.getResponse() == null ? 0 : e.getResponse().getStatusCode();
                if (status != 404) {
                    log.warn("Could not check vault {} for certificate {}: {}", vault.getName(),
                            certName, e.getMessage());
                }
            } catch (Exception e) {
                log.warn("Could not check vault {} for certificate {}: {}", vault.getName(), certName,
                        e.getMessage());
            }
        }
        if (hits.size() == 1) {
            log.info("Certificate {} located in vault {}", certName, hits.get(0).getName());
            return Result.success(hits.get(0));
        }
        if (hits.isEmpty()) {
            return Result.failure("Certificate '" + certName + "' was not found in any vault of "
                    + "subscription " + config.getSubscriptionId() + "; specify the vault as "
                    + "<vault>/" + certName, ErrorCode.VAULT_NOT_FOUND.name());
        }
        final var names = hits.stream().map(KeyVaultInfo::getName).toList();
        return Result.failure("Certificate '" + certName + "' exists in more than one vault " + names
                + "; specify the vault as <vault>/" + certName, ErrorCode.AMBIGUOUS_TARGET.name());
    }

    // ------------------------------------------------------------------ generateCsr

    public Result<AzureKeyVaultGeneratedCsr> generateCsr(
            KeyVaultInfo vault,
            String certName,
            String subjectDn,
            List<String> dnsNames,
            List<String> emails,
            String keySize,
            String keyType) {
        try {
            if (subjectDn == null || subjectDn.isBlank()) {
                return Result.failure("A subject DN is required to create a Key Vault certificate",
                        ErrorCode.CERTIFICATE_CREATION_ERROR.name());
            }
            log.info("Creating Key Vault certificate {}/{} — subject=[{}], dnsNames={}, emails={}, "
                    + "keyType={}, keySize={}", vault.getName(), certName, subjectDn, dnsNames, emails,
                    keyType, keySize);

            CertificateOperation operation;
            try {
                operation = startCertificateOperation(vault, certName,
                        buildPolicy(subjectDn, dnsNames, emails, keyType, keySize));
            } catch (HttpResponseException e) {
                // Azure rejects some DigiCert subject DNs ("Invalid X.500 distinguished name").
                // Retry with a CN-only subject: for most DigiCert products the issued subject comes
                // from the TLM order, not the CSR.
                final var cn = CertificateAttributesUtil.getCommonName(subjectDn);
                if (isInvalidSubjectError(e) && cn != null && !cn.isBlank()
                        && !subjectDn.equalsIgnoreCase("CN=" + cn)) {
                    log.warn("Azure rejected subject [{}] ({}). Retrying with CN-only subject [CN={}].",
                            subjectDn, e.getMessage(), cn);
                    operation = startCertificateOperation(vault, certName,
                            buildPolicy("CN=" + cn, dnsNames, emails, keyType, keySize));
                } else {
                    throw e;
                }
            }

            if (operation == null || operation.getCsr() == null) {
                final var detail = operation != null && operation.getStatusDetails() != null
                        ? operation.getStatusDetails() : "no CSR returned";
                return Result.failure("Key Vault did not return a CSR for " + vault.getName() + "/"
                        + certName + ": " + detail, ErrorCode.CERTIFICATE_CREATION_ERROR.name());
            }

            final var generated = new AzureKeyVaultGeneratedCsr();
            generated.setCsr(derToPem(operation.getCsr(), "CERTIFICATE REQUEST"));
            generated.setWarnings(new ArrayList<>());
            return Result.success(generated);
        } catch (Exception e) {
            log.error("Error during generateCsr for {}/{}", vault.getName(), certName, e);
            return Result.failure(e.getMessage(), classify(e));
        }
    }

    private CertificateOperation startCertificateOperation(KeyVaultInfo vault, String certName,
                                                           CertificatePolicy policy) {
        final SyncPoller<CertificateOperation, KeyVaultCertificateWithPolicy> poller =
                getCertificateClient(vault).beginCreateCertificate(certName, policy);
        return poller.waitUntil(LongRunningOperationStatus.IN_PROGRESS).getValue();
    }

    private static boolean isInvalidSubjectError(HttpResponseException e) {
        final int status = e.getResponse() == null ? 0 : e.getResponse().getStatusCode();
        final var msg = e.getMessage() == null ? "" : e.getMessage().toLowerCase();
        return status == 400 && (msg.contains("x509_props") || msg.contains("distinguished name"));
    }

    private CertificatePolicy buildPolicy(String subjectDn, List<String> dnsNames,
                                          List<String> emails, String keyType, String keySize) {
        final var policy = new CertificatePolicy(UNKNOWN_ISSUER, subjectDn);
        final boolean hasDns = dnsNames != null && !dnsNames.isEmpty();
        final boolean hasEmails = emails != null && !emails.isEmpty();
        if (hasDns || hasEmails) {
            final var san = new SubjectAlternativeNames();
            if (hasDns) {
                san.setDnsNames(dnsNames);
            }
            if (hasEmails) {
                san.setEmails(emails);
            }
            policy.setSubjectAlternativeNames(san);
        }
        if (keyType != null && keyType.toLowerCase().startsWith("ec")) {
            policy.setKeyType(CertificateKeyType.EC);
            policy.setKeyCurveName(CertificateKeyCurveName.fromString(
                    "P-" + parseIntOrDefault(keySize, 256)));
        } else {
            policy.setKeyType(CertificateKeyType.RSA);
            policy.setKeySize(parseIntOrDefault(keySize, 2048));
        }
        return policy;
    }

    // ------------------------------------------------------------------ installCertificate

    public Result<Void> installCertificate(KeyVaultInfo vault, String certName, List<String> pemChain,
                                           String currentCertificateThumbprint) {
        try {
            final List<byte[]> ders = new ArrayList<>();
            for (String pem : pemChain) {
                if (pem != null && !pem.isBlank()) {
                    ders.addAll(pemToDerList(pem));
                }
            }
            if (ders.isEmpty()) {
                return Result.failure("No certificates found in the supplied chain to merge",
                        ErrorCode.CERTIFICATE_MERGE_ERROR.name());
            }
            if (currentCertificateThumbprint != null && !currentCertificateThumbprint.isBlank()) {
                log.info("Merging new version of certificate {}/{} (replacing thumbprint {})",
                        vault.getName(), certName, currentCertificateThumbprint);
            }
            getCertificateClient(vault).mergeCertificate(new MergeCertificateOptions(certName, ders));
            return Result.success();
        } catch (Exception e) {
            log.error("Error during installCertificate for {}/{}", vault.getName(), certName, e);
            return Result.failure(e.getMessage(), classify(e));
        }
    }

    // ------------------------------------------------------------------ validateCertificate

    public Result<AzureKeyVaultInstalledCertificate> validateCertificate(KeyVaultInfo vault,
                                                                         String certName) {
        try {
            final var cert = getCertificateClient(vault).getCertificate(certName);
            if (cert == null || cert.getCer() == null) {
                return Result.failure("Certificate " + vault.getName() + "/" + certName
                        + " has no active version in the vault",
                        ErrorCode.CERTIFICATE_VALIDATION_ERROR.name());
            }
            final var installed = new AzureKeyVaultInstalledCertificate();
            installed.setCertificate(derToPem(cert.getCer(), "CERTIFICATE"));
            return Result.success(installed);
        } catch (Exception e) {
            log.error("Error during validateCertificate for {}/{}", vault.getName(), certName, e);
            return Result.failure(e.getMessage(), classify(e));
        }
    }

    // ------------------------------------------------------------------ clients + helpers

    private List<KeyVaultInfo> refreshVaultCache() {
        final var vaults = armClient.listVaults();
        final Map<String, KeyVaultInfo> byName = new ConcurrentHashMap<>();
        for (KeyVaultInfo v : vaults) {
            if (v.getName() != null) {
                byName.put(v.getName().toLowerCase(Locale.ROOT), v);
            }
        }
        vaultCache = byName;
        return vaults;
    }

    private CertificateClient getCertificateClient(KeyVaultInfo vault) {
        return clients.computeIfAbsent(vault.getVaultUri(), uri -> new CertificateClientBuilder()
                .httpClient(AzureCredentialsProvider.createHttpClientBuilder().build())
                .vaultUrl(uri)
                .credential(credentialsProvider.getClientSecretCredential())
                .buildClient());
    }

    private <T> Result<T> armFailure(String action, Exception e) {
        log.error("Azure Resource Manager error while {}", action, e);
        final var msg = e.getMessage() == null ? "" : e.getMessage();
        if (e instanceof HttpResponseException hre) {
            final int status = hre.getResponse() == null ? 0 : hre.getResponse().getStatusCode();
            if (status == 401 || status == 403) {
                return Result.failure("Unauthorized while " + action + ": grant the service principal "
                        + "the Reader role on the subscription (or on the filtered resource groups). "
                        + msg, ErrorCode.UNAUTHORIZED.name());
            }
            if (status == 404) {
                return Result.failure("Subscription " + config.getSubscriptionId() + " was not found "
                        + "for this tenant/principal. " + msg, ErrorCode.SUBSCRIPTION_NOT_FOUND.name());
            }
        }
        return Result.failure("Error while " + action + ": " + msg, classify(e));
    }

    static String derToPem(byte[] der, String type) {
        if (der == null) {
            return null;
        }
        final var base64 = Base64.getEncoder().encodeToString(der);
        final var body = new StringBuilder();
        for (int i = 0; i < base64.length(); i += 64) {
            body.append(base64, i, Math.min(i + 64, base64.length())).append('\n');
        }
        return "-----BEGIN " + type + "-----\n" + body + "-----END " + type + "-----\n";
    }

    private static List<byte[]> pemToDerList(String pem) throws Exception {
        final var factory = CertificateFactory.getInstance("X.509");
        final List<byte[]> ders = new ArrayList<>();
        try (var in = new ByteArrayInputStream(pem.getBytes(StandardCharsets.UTF_8))) {
            for (var cert : factory.generateCertificates(in)) {
                ders.add(((X509Certificate) cert).getEncoded());
            }
        }
        return ders;
    }

    private static X509Certificate parseX509(byte[] der) {
        try {
            final var factory = CertificateFactory.getInstance("X.509");
            return (X509Certificate) factory.generateCertificate(new ByteArrayInputStream(der));
        } catch (Exception e) {
            return null;
        }
    }

    private static String bytesToHexUpper(byte[] bytes) {
        final var sb = new StringBuilder(bytes.length * 2);
        for (byte b : bytes) {
            sb.append(String.format("%02X", b));
        }
        return sb.toString();
    }

    private static boolean isExpired(OffsetDateTime expiresOn) {
        return expiresOn != null && expiresOn.isBefore(OffsetDateTime.now());
    }

    private static int parseIntOrDefault(String value, int fallback) {
        try {
            return value == null ? fallback : Integer.parseInt(value.trim());
        } catch (NumberFormatException e) {
            return fallback;
        }
    }

    private static String shortMessage(Exception e) {
        final var m = e.getMessage() == null ? e.getClass().getSimpleName() : e.getMessage();
        final var oneLine = m.replaceAll("\\s+", " ").trim();
        return oneLine.length() > 160 ? oneLine.substring(0, 160) + "…" : oneLine;
    }

    private static String classify(Exception e) {
        return e instanceof AzureException
                ? ErrorCode.AZURE_EXCEPTION.name() : ErrorCode.INTERNAL_ERROR.name();
    }

    /** Exposed for tests. */
    Optional<Map<String, KeyVaultInfo>> cachedVaults() {
        return Optional.ofNullable(vaultCache);
    }
}
