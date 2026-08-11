package com.example.automation.adapter;

import java.io.ByteArrayInputStream;
import java.nio.charset.StandardCharsets;
import java.security.cert.CertificateFactory;
import java.security.cert.X509Certificate;
import java.time.OffsetDateTime;
import java.util.ArrayList;
import java.util.Base64;
import java.util.List;
import java.util.Optional;

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
import com.example.automation.model.AzureKeyVaultConfigurationData;
import com.example.automation.model.AzureKeyVaultConfigurationData.CertificateAsset;
import com.example.automation.model.AzureKeyVaultConfigurationData.VaultInfo;
import com.example.automation.model.AzureKeyVaultGeneratedCsr;
import com.example.automation.model.AzureKeyVaultInstalledCertificate;
import com.example.automation.model.Connection;
import com.example.automation.model.ErrorCode;
import com.example.automation.model.Result;
import com.example.automation.helper.CertificateAttributesUtil;

import lombok.extern.slf4j.Slf4j;

/**
 * Drives all certificate-lifecycle operations against a single Azure Key Vault over the Azure
 * Certificates SDK.
 *
 * <p>The private key never leaves Azure: {@code generateCsr} creates the certificate with the
 * {@code Unknown} issuer (Azure generates the key and returns a CSR), and {@code installCertificate}
 * merges the CA-signed certificate back in. Because Azure Key Vault treats a create against an
 * existing certificate <em>name</em> as a new version, renewing a discovered certificate is simply a
 * matter of reusing its name — the signed result lands as a new version of the same certificate.
 */
@Slf4j
public class AzureKeyVaultAdapter {

    private static final String UNKNOWN_ISSUER = "Unknown";

    private final AzureCredentialsProvider credentialsProvider;
    private final String vaultUrl;
    private volatile CertificateClient certificateClient;

    public AzureKeyVaultAdapter(AdapterConfig config) {
        this.credentialsProvider = new AzureCredentialsProvider(config);
        this.vaultUrl = config.getVaultUrl();
    }

    // ------------------------------------------------------------------ testConnection

    public Result<Connection> testConnection() {
        try {
            // Enumerating the first page exercises auth + network + list permission on the vault.
            getCertificateClient().listPropertiesOfCertificates().iterator().hasNext();
            return Result.success(new Connection(true));
        } catch (HttpResponseException e) {
            final int status = e.getResponse() == null ? 0 : e.getResponse().getStatusCode();
            if (status == 401 || status == 403) {
                return Result.failure("Unauthorized: " + e.getMessage(), ErrorCode.UNAUTHORIZED.name());
            }
            log.error("Azure error during testConnection", e);
            return Result.failure(e.getMessage(), ErrorCode.AZURE_EXCEPTION.name());
        } catch (Exception e) {
            log.error("Error during testConnection", e);
            return Result.failure(e.getMessage(), classify(e));
        }
    }

    // ------------------------------------------------------------------ refreshConfiguration

    /**
     * Builds the inventory of certificate assets held in the vault.
     *
     * <p>By default every certificate object is surfaced — including expired, disabled and
     * self-signed ones, which are exactly the certificates an operator may want to replace. The two
     * flags let a connector opt into trimming the inventory; both default to false (show all).
     *
     * @param excludeExpired  when true, omit certificates whose active version has expired
     * @param excludeDisabled when true, omit certificates disabled in the vault
     */
    public Result<AzureKeyVaultConfigurationData> getConfigurationData(
            boolean excludeExpired, boolean excludeDisabled) {
        try {
            final var client = getCertificateClient();
            final var data = new AzureKeyVaultConfigurationData();

            final var vaultInfo = new VaultInfo();
            vaultInfo.setVaultUrl(vaultUrl);
            vaultInfo.setVaultName(vaultNameFromUrl(vaultUrl));
            data.setVaultInfo(vaultInfo);

            // Filter on the cheap list metadata (enabled flag + expiry) BEFORE the per-certificate
            // getCertificate fetch, so excluded certs cost no extra round-trip. Skips are logged so
            // trimming is never silent.
            final List<CertificateAsset> assets = new ArrayList<>();
            int skippedExpired = 0;
            int skippedDisabled = 0;
            for (CertificateProperties props : client.listPropertiesOfCertificates()) {
                if (excludeDisabled && !Boolean.TRUE.equals(props.isEnabled())) {
                    skippedDisabled++;
                    log.info("Excluding disabled certificate {}", props.getName());
                    continue;
                }
                if (excludeExpired && isExpired(props.getExpiresOn())) {
                    skippedExpired++;
                    log.info("Excluding expired certificate {} (expired {})",
                            props.getName(), props.getExpiresOn());
                    continue;
                }
                assets.add(toAsset(client, props));
            }
            data.setCertificates(assets);
            log.info("RefreshConfiguration discovered {} certificate(s) in vault {} "
                    + "(excluded {} expired, {} disabled)",
                    assets.size(), vaultInfo.getVaultName(), skippedExpired, skippedDisabled);
            return Result.success(data);
        } catch (Exception e) {
            log.error("Error during getConfigurationData", e);
            return Result.failure(e.getMessage(), classify(e));
        }
    }

    private CertificateAsset toAsset(CertificateClient client, CertificateProperties props) {
        final var asset = new CertificateAsset();
        asset.setName(props.getName());
        asset.setEnabled(Boolean.TRUE.equals(props.isEnabled()));
        asset.setExpiresOn(props.getExpiresOn() == null ? null : props.getExpiresOn().toString());
        asset.setThumbprint(props.getX509Thumbprint() == null
                ? null : bytesToHexUpper(props.getX509Thumbprint()));
        // Best-effort: fetch the active version's PEM, subject, and self-signed flag. Azure blocks
        // reading a DISABLED certificate's material, so on failure we still surface the asset by
        // name/thumbprint (it must remain visible so an operator can act on it) — just without the
        // cert detail until it is re-enabled. Never fail the whole refresh over one certificate.
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
            log.warn("Certificate {} is present but its material could not be read (it may be "
                    + "disabled); surfacing it as a name-only asset. Reason: {}",
                    props.getName(), e.getMessage());
        }
        log.info("Discovered certificate: name={}, enabled={}, selfSigned={}, expiresOn={}, thumbprint={}",
                asset.getName(), asset.isEnabled(), asset.isSelfSigned(),
                asset.getExpiresOn(), asset.getThumbprint());
        return asset;
    }

    // ------------------------------------------------------------------ generateCsr

    /**
     * Creates (or starts a new version of) the certificate {@code certName} with the {@code Unknown}
     * issuer so Azure generates the key and returns a CSR, then PEM-wraps and returns that CSR.
     *
     * @param subjectDn full subject DN, e.g. {@code CN=example.com,O=Example,C=US}
     * @param dnsNames  SubjectAltName DNS entries (may be empty)
     * @param keyType   {@code "ec"} for an elliptic-curve key, anything else → RSA
     * @param keySize   RSA modulus bits, or the EC curve size (e.g. {@code 256})
     */
    public Result<AzureKeyVaultGeneratedCsr> generateCsr(
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
            log.info("Creating Key Vault certificate {} — subject=[{}], dnsNames={}, emails={}, "
                    + "keyType={}, keySize={}", certName, subjectDn, dnsNames, emails, keyType, keySize);

            CertificateOperation operation;
            try {
                operation = startCertificateOperation(certName,
                        buildPolicy(subjectDn, dnsNames, emails, keyType, keySize));
            } catch (HttpResponseException e) {
                // Azure rejects some DigiCert subject DNs (e.g. an org name containing a comma, or a
                // non-RFC-4514 attribute) with "Invalid X.500 distinguished name". Rather than fail
                // the renewal, retry with a CN-only subject. For most DigiCert products the issued
                // certificate's subject is taken from the TLM order, not the CSR, so this only
                // affects the CSR's subject. The full subject is logged above for diagnosis.
                final var cn = CertificateAttributesUtil.getCommonName(subjectDn);
                if (isInvalidSubjectError(e) && cn != null && !cn.isBlank()
                        && !subjectDn.equalsIgnoreCase("CN=" + cn)) {
                    log.warn("Azure rejected subject [{}] ({}). Retrying with CN-only subject [CN={}].",
                            subjectDn, e.getMessage(), cn);
                    operation = startCertificateOperation(certName,
                            buildPolicy("CN=" + cn, dnsNames, emails, keyType, keySize));
                } else {
                    throw e;
                }
            }

            if (operation == null || operation.getCsr() == null) {
                final var detail = operation != null && operation.getStatusDetails() != null
                        ? operation.getStatusDetails() : "no CSR returned";
                return Result.failure("Key Vault did not return a CSR for " + certName + ": " + detail,
                        ErrorCode.CERTIFICATE_CREATION_ERROR.name());
            }

            final var generated = new AzureKeyVaultGeneratedCsr();
            generated.setCsr(derToPem(operation.getCsr(), "CERTIFICATE REQUEST"));
            generated.setWarnings(new ArrayList<>());
            return Result.success(generated);
        } catch (Exception e) {
            log.error("Error during generateCsr for {}", certName, e);
            return Result.failure(e.getMessage(), classify(e));
        }
    }

    /** Starts a create-certificate operation and returns it once the CSR is available. */
    private CertificateOperation startCertificateOperation(String certName, CertificatePolicy policy) {
        final SyncPoller<CertificateOperation, KeyVaultCertificateWithPolicy> poller =
                getCertificateClient().beginCreateCertificate(certName, policy);
        return poller.waitUntil(LongRunningOperationStatus.IN_PROGRESS).getValue();
    }

    /** True for the Azure 400 that signals an unparseable/invalid subject DN. */
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
            // Azure rejects an empty SubjectAlternativeNames object, so only attach it when populated.
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

    /**
     * Merges the CA-signed certificate chain into the pending certificate operation started by
     * {@link #generateCsr}, completing it as a new active version of {@code certName}.
     *
     * @param pemChain end-entity PEM first, then any intermediate CA PEMs
     */
    public Result<Void> installCertificate(String certName, List<String> pemChain,
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
                log.info("Merging new version of certificate {} (replacing thumbprint {})",
                        certName, currentCertificateThumbprint);
            }

            getCertificateClient().mergeCertificate(new MergeCertificateOptions(certName, ders));
            return Result.success();
        } catch (Exception e) {
            log.error("Error during installCertificate for {}", certName, e);
            return Result.failure(e.getMessage(), classify(e));
        }
    }

    // ------------------------------------------------------------------ validateCertificate

    /** Returns the PEM of the active version currently held under {@code certName}. */
    public Result<AzureKeyVaultInstalledCertificate> validateCertificate(String certName) {
        try {
            final var cert = getCertificateClient().getCertificate(certName);
            if (cert == null || cert.getCer() == null) {
                return Result.failure("Certificate " + certName + " has no active version in the vault",
                        ErrorCode.CERTIFICATE_VALIDATION_ERROR.name());
            }
            final var installed = new AzureKeyVaultInstalledCertificate();
            installed.setCertificate(derToPem(cert.getCer(), "CERTIFICATE"));
            return Result.success(installed);
        } catch (Exception e) {
            log.error("Error during validateCertificate for {}", certName, e);
            return Result.failure(e.getMessage(), classify(e));
        }
    }

    // ------------------------------------------------------------------ client + helpers

    private CertificateClient getCertificateClient() {
        if (certificateClient == null) {
            synchronized (this) {
                if (certificateClient == null) {
                    certificateClient = new CertificateClientBuilder()
                            .httpClient(AzureCredentialsProvider.createHttpClientBuilder().build())
                            .vaultUrl(vaultUrl)
                            .credential(credentialsProvider.getClientSecretCredential())
                            .buildClient();
                }
            }
        }
        return certificateClient;
    }

    /** Extracts the short vault name from a vault URL host (e.g. {@code https://foo.vault.azure.net/} → {@code foo}). */
    static String vaultNameFromUrl(String url) {
        if (url == null || url.isBlank()) {
            return null;
        }
        var host = url.replaceFirst("^https?://", "");
        final int slash = host.indexOf('/');
        if (slash >= 0) {
            host = host.substring(0, slash);
        }
        final int dot = host.indexOf('.');
        return dot > 0 ? host.substring(0, dot) : host;
    }

    /** Wraps DER bytes as a 64-column PEM block of the given type. */
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

    /** Parses a PEM string (one or more certificates) into a list of DER byte arrays. */
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

    /** Best-effort parse of a DER-encoded X.509 certificate, or null. */
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

    private static String classify(Exception e) {
        return e instanceof AzureException
                ? ErrorCode.AZURE_EXCEPTION.name() : ErrorCode.INTERNAL_ERROR.name();
    }

    /** Exposed for tests; the plugin uses only the lifecycle methods above. */
    Optional<String> vaultName() {
        return Optional.ofNullable(vaultNameFromUrl(vaultUrl));
    }
}
