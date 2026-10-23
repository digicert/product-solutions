package com.example.automation;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNotEquals;
import static org.junit.jupiter.api.Assertions.assertNotNull;
import static org.junit.jupiter.api.Assertions.assertTrue;

import java.time.Instant;
import java.time.temporal.ChronoUnit;
import java.util.List;

import org.junit.jupiter.api.AfterEach;
import org.junit.jupiter.api.BeforeEach;
import org.junit.jupiter.api.Test;

import com.example.automation.adapter.AdapterConfig;
import com.example.automation.adapter.CloudflareAdapter;
import com.example.automation.model.CloudflareCertificate;
import com.example.automation.model.CloudflareInstalledCertificate;
import com.example.automation.model.ErrorCode;

class CloudflareAdapterTest {

    private MockCloudflareServer server;

    @BeforeEach
    void start() throws Exception {
        server = new MockCloudflareServer();
    }

    @AfterEach
    void stop() {
        server.close();
    }

    private AdapterConfig.AdapterConfigBuilder config() {
        return AdapterConfig.builder()
                .apiBaseUrl(server.baseUrl())
                .zoneId(MockCloudflareServer.ZONE_ID)
                .apiToken(MockCloudflareServer.TOKEN)
                .csrMode(AdapterConfig.CSR_MODE_CLOUDFLARE)
                .csrSubjectFallback("C=US, ST=Utah, L=Lehi, O=DigiCert")
                .renewalStrategy(AdapterConfig.STRATEGY_UPDATE)
                .certificateType(AdapterConfig.TYPE_SNI_CUSTOM)
                .bundleMethod(AdapterConfig.BUNDLE_FORCE)
                .csrRetention(1)
                .managedMode(AdapterConfig.MANAGED_DISCOVER_KEEP)
                .probeBudgetMillis(0);
    }

    private static final String ZP = "/zones/" + MockCloudflareServer.ZONE_ID;

    @Test
    void testConnectionSucceedsAndListsCertificates() throws Exception {
        server.seed(List.of("example.test", "www.example.test"), Instant.now().plus(100, ChronoUnit.DAYS), "active");
        final var adapter = new CloudflareAdapter(config().build());
        final var result = adapter.testConnection();
        assertTrue(result.isSuccess(), result.getErrorMessage());
        assertTrue(result.getValue().isActive());
        assertTrue(server.requests.stream().anyMatch(r -> r.startsWith("GET /user/tokens/verify")));
        assertTrue(server.requests.stream().anyMatch(r -> r.contains("/custom_certificates?page=1&per_page=50")));
    }

    @Test
    void testConnectionReportsBadToken() {
        final var adapter = new CloudflareAdapter(config().apiToken("wrong").build());
        final var result = adapter.testConnection();
        assertFalse(result.isSuccess());
        // the mock answers 400 code 10000 like Cloudflare; the zone read then fails with the same
        assertTrue(result.getErrorMessage().contains("Authentication error"), result.getErrorMessage());
    }

    @Test
    void testConnectionReportsRejectedTokenAsUnauthorized() {
        server.tokenStatusCode = 401;
        final var adapter = new CloudflareAdapter(config().build());
        final var result = adapter.testConnection();
        assertFalse(result.isSuccess());
        assertEquals(ErrorCode.UNAUTHORIZED.name(), result.getErrorCode());
    }

    @Test
    void listCertificatesPaginatesAndSkipsDeleted() throws Exception {
        for (int i = 0; i < 55; i++) {
            server.seed(List.of("host" + i + ".example.test"), Instant.now().plus(10 + i, ChronoUnit.DAYS), "active");
        }
        server.seed(List.of("gone.example.test"), Instant.now().plus(1, ChronoUnit.DAYS), "deleted");
        final var adapter = new CloudflareAdapter(config().build());
        final var certs = adapter.listCertificates();
        assertEquals(55, certs.size());
        assertTrue(server.requests.stream().anyMatch(r -> r.contains("page=2&per_page=50")));
        assertNotNull(certs.get(0).getExpiresOnEpoch());
        assertEquals("host0.example.test", certs.get(0).primaryHost());
        assertEquals("sni_custom", certs.get(0).getType());
        assertTrue(certs.get(0).isSni());
        assertTrue(adapter.getCertificate("00000000-0000-0000-0000-000000000000").isEmpty());
    }

    @Test
    void discoveryWithoutBodiesStillReturnsMetadata() {
        server.seed(List.of("*.example.test", "example.test"), Instant.now().plus(30, ChronoUnit.DAYS), "active");
        final var adapter = new CloudflareAdapter(config().build());
        final var data = adapter.getConfigurationData();
        assertTrue(data.isSuccess(), data.getErrorMessage());
        assertEquals("example.test", data.getValue().getZone().getName());
        assertEquals(1, data.getValue().getCertificates().size());
        final var c = data.getValue().getCertificates().get(0);
        assertEquals("example.test", c.primaryHost());
        assertEquals(null, c.getCertificatePem());
    }

    @Test
    void createCsrUsesSubjectDnThenFallbackAndMapsKeyType() {
        final var adapter = new CloudflareAdapter(config().build());
        final var result = adapter.createCsr("CN=www.example.test, O=Example Ltd, C=GB", List.of("www.example.test", "example.test"),
                "RSA", "4096");
        assertTrue(result.isSuccess(), result.getErrorMessage());
        assertNotNull(result.getValue().getCustomCsrId());
        assertTrue(result.getValue().getCsr().startsWith("-----BEGIN CERTIFICATE REQUEST-----"));
        final var stored = server.csrs.get(result.getValue().getCustomCsrId());
        assertEquals("www.example.test", stored.path("common_name").asText());
        assertEquals("GB", stored.path("country").asText());
        assertEquals("Example Ltd", stored.path("organization").asText());
        assertEquals("Utah", stored.path("state").asText());
        assertEquals("Lehi", stored.path("locality").asText());
        assertEquals("rsa2048", stored.path("key_type").asText());
        assertEquals(2, stored.path("sans").size());

        final var ec = adapter.createCsr("CN=ec.example.test", List.of(), "EC", "384");
        assertTrue(ec.isSuccess());
        assertEquals("p256v1", server.csrs.get(ec.getValue().getCustomCsrId()).path("key_type").asText());
    }

    @Test
    void createCsrFailsWhenSubjectAttributesMissing() {
        final var adapter = new CloudflareAdapter(config().csrSubjectFallback("").build());
        final var result = adapter.createCsr("CN=www.example.test", List.of(), "RSA", "2048");
        assertFalse(result.isSuccess());
        assertTrue(result.getErrorMessage().contains("[C, ST, L, O]"), result.getErrorMessage());
    }

    @Test
    void installUpdatesInPlaceAndFollowsTheIdCloudflareReturns() throws Exception {
        final var oldId = server.seed(List.of("www.example.test", "example.test"), Instant.now().plus(10, ChronoUnit.DAYS), "active");
        final var issued = TestCerts.selfSigned("www.example.test", List.of("www.example.test", "example.test"),
                Instant.now().plus(390, ChronoUnit.DAYS));
        final var adapter = new CloudflareAdapter(config().build());
        server.pendingReadsBeforeActive.set(1); // live: the PATCH result is 'pending' first
        final var result = adapter.installCertificate(issued.pem(), issued.keyPem(), null, issued.certificate(), List.of(oldId));
        assertTrue(result.isSuccess(), result.getErrorMessage());
        final var newId = result.getValue().getCertificateId();
        assertNotEquals(oldId, newId);                       // Cloudflare re-issues under a new id
        assertEquals("update", result.getValue().getAction());
        assertEquals("active", result.getValue().getStatus());
        assertEquals(List.of(oldId), result.getValue().getDeletedCertificates());
        assertTrue(server.requests.stream().anyMatch(r -> r.equals("PATCH /zones/" + MockCloudflareServer.ZONE_ID + "/custom_certificates/" + oldId)));
        assertFalse(server.requests.stream().anyMatch(r -> r.startsWith("POST") && r.endsWith("/custom_certificates")));
        assertEquals(1, server.certificates.size());
        assertFalse(server.certificates.containsKey(oldId));
        assertEquals(issued.certificate().getNotAfter().toInstant().toString(), server.certificates.get(newId).path("expires_on").asText());
    }

    @Test
    void installFallsBackToUploadAndDeleteWhenPatchIsRefused() throws Exception {
        server.rejectPatch = true;
        final var oldId = server.seed(List.of("www.example.test"), Instant.now().plus(10, ChronoUnit.DAYS), "active");
        final var issued = TestCerts.selfSigned("www.example.test", List.of("www.example.test"), Instant.now().plus(390, ChronoUnit.DAYS));
        final var adapter = new CloudflareAdapter(config().build());
        final var result = adapter.installCertificate(issued.pem(), issued.keyPem(), null, issued.certificate(), List.of(oldId));
        assertTrue(result.isSuccess(), result.getErrorMessage());
        assertNotEquals(oldId, result.getValue().getCertificateId());
        assertEquals("upload", result.getValue().getAction());
        assertEquals(List.of(oldId), result.getValue().getDeletedCertificates());
        assertEquals(1, server.certificates.size());
    }

    @Test
    void installWithReplaceDeleteUploadsNewAndDeletesOld() throws Exception {
        final var oldId = server.seed(List.of("www.example.test"), Instant.now().plus(10, ChronoUnit.DAYS), "active");
        final var issued = TestCerts.selfSigned("www.example.test", List.of("www.example.test"), Instant.now().plus(390, ChronoUnit.DAYS));
        final var adapter = new CloudflareAdapter(config().renewalStrategy(AdapterConfig.STRATEGY_REPLACE_DELETE)
                .certificateType(AdapterConfig.TYPE_LEGACY_CUSTOM).build());
        server.pendingReadsBeforeActive.set(2);
        final var result = adapter.installCertificate(issued.pem(), issued.keyPem(), null, issued.certificate(), List.of(oldId));
        assertTrue(result.isSuccess(), result.getErrorMessage());
        final var newId = result.getValue().getCertificateId();
        assertNotEquals(oldId, newId);
        assertEquals("active", result.getValue().getStatus());
        assertEquals(List.of(oldId), result.getValue().getDeletedCertificates());
        assertFalse(server.certificates.containsKey(oldId));
        assertTrue(server.certificates.containsKey(newId));
        assertFalse(server.requests.stream().anyMatch(r -> r.startsWith("PATCH")));
    }

    @Test
    void installWithReplaceKeepRetainsOld() throws Exception {
        final var oldId = server.seed(List.of("www.example.test"), Instant.now().plus(10, ChronoUnit.DAYS), "active");
        final var issued = TestCerts.selfSigned("www.example.test", List.of("www.example.test"), Instant.now().plus(390, ChronoUnit.DAYS));
        final var adapter = new CloudflareAdapter(config().renewalStrategy(AdapterConfig.STRATEGY_REPLACE_KEEP).build());
        final var result = adapter.installCertificate(issued.pem(), issued.keyPem(), null, issued.certificate(), List.of(oldId));
        assertTrue(result.isSuccess(), result.getErrorMessage());
        assertEquals(List.of(oldId), result.getValue().getRetainedCertificates());
        assertEquals(2, server.certificates.size());
    }

    @Test
    void installUsesCloudflareCsrIdWithoutPrivateKeyAndCleansUpOldCsrs() throws Exception {
        final var adapter = new CloudflareAdapter(config().build());
        final var first = adapter.createCsr("CN=www.example.test, C=US, ST=Utah, L=Lehi, O=Test", List.of("www.example.test"), "RSA", "2048");
        final var second = adapter.createCsr("CN=www.example.test, C=US, ST=Utah, L=Lehi, O=Test", List.of("www.example.test"), "RSA", "2048");
        final var current = adapter.createCsr("CN=www.example.test, C=US, ST=Utah, L=Lehi, O=Test", List.of("www.example.test"), "RSA", "2048");
        final var other = adapter.createCsr("CN=other.example.test, C=US, ST=Utah, L=Lehi, O=Test", List.of("other.example.test"), "RSA", "2048");
        final var issued = TestCerts.selfSigned("www.example.test", List.of("www.example.test"), Instant.now().plus(390, ChronoUnit.DAYS));

        final var result = adapter.installCertificate(issued.pem(), null, current.getValue().getCustomCsrId(), issued.certificate(), List.of());
        assertTrue(result.isSuccess(), result.getErrorMessage());
        assertEquals("upload", result.getValue().getAction());
        final var stored = server.certificates.get(result.getValue().getCertificateId());
        assertEquals(current.getValue().getCustomCsrId(), stored.path("custom_csr_id").asText());

        // retention 1: of the three www CSRs, the current one is always kept plus 1 older → the oldest goes
        final int deleted = adapter.cleanupCsrs("www.example.test", current.getValue().getCustomCsrId(), 1);
        assertEquals(1, deleted);
        assertFalse(server.csrs.containsKey(first.getValue().getCustomCsrId()));
        assertTrue(server.csrs.containsKey(second.getValue().getCustomCsrId()));
        assertTrue(server.csrs.containsKey(current.getValue().getCustomCsrId()));
        assertTrue(server.csrs.containsKey(other.getValue().getCustomCsrId()));
    }

    @Test
    void installIsIdempotentWhenTheLeafIsAlreadyPresent() throws Exception {
        final var issued = TestCerts.selfSigned("www.example.test", List.of("www.example.test"), Instant.now().plus(390, ChronoUnit.DAYS));
        final var existingId = server.seed(List.of("www.example.test"), issued.certificate().getNotAfter().toInstant(), "active");
        final var oldId = server.seed(List.of("www.example.test"), Instant.now().plus(10, ChronoUnit.DAYS), "active");
        final var adapter = new CloudflareAdapter(config().renewalStrategy(AdapterConfig.STRATEGY_REPLACE_DELETE).build());
        final var result = adapter.installCertificate(issued.pem(), issued.keyPem(), null, issued.certificate(), List.of(oldId));
        assertTrue(result.isSuccess(), result.getErrorMessage());
        assertEquals(existingId, result.getValue().getCertificateId());
        assertEquals("existing", result.getValue().getAction());
        assertEquals(List.of(oldId), result.getValue().getDeletedCertificates());
        assertFalse(server.requests.stream().anyMatch(r -> r.startsWith("POST") && r.contains("custom_certificates")));
    }

    @Test
    void installReportsUploadErrors() throws Exception {
        final var issued = TestCerts.selfSigned("www.example.test", List.of("www.example.test"), Instant.now().plus(390, ChronoUnit.DAYS));
        final var adapter = new CloudflareAdapter(config().build());
        final var result = adapter.installCertificate(issued.pem(), null, "does-not-exist", issued.certificate(), List.of());
        assertFalse(result.isSuccess());
        assertEquals(ErrorCode.CERTIFICATE_UPLOAD_ERROR.name(), result.getErrorCode());
        assertTrue(result.getErrorMessage().contains("code 1002"), result.getErrorMessage());
    }

    @Test
    void validateChecksStatusAndExpiry() throws Exception {
        final var expires = Instant.now().plus(390, ChronoUnit.DAYS).truncatedTo(ChronoUnit.SECONDS);
        final var id = server.seed(List.of("www.example.test"), expires, "active");
        final var adapter = new CloudflareAdapter(config().build());
        assertTrue(adapter.validateCertificate(id, "0A", expires.getEpochSecond(), "example.test").isSuccess());

        final var mismatch = adapter.validateCertificate(id, "0A", expires.getEpochSecond() + 86_400, "example.test");
        assertFalse(mismatch.isSuccess());
        assertTrue(mismatch.getErrorMessage().contains("expires on"), mismatch.getErrorMessage());

        final var missing = adapter.validateCertificate("nope", null, null, "example.test");
        assertFalse(missing.isSuccess());
        assertEquals(ErrorCode.CERTIFICATE_VALIDATION_ERROR.name(), missing.getErrorCode());

        final var expiredId = server.seed(List.of("old.example.test"), Instant.now().minus(1, ChronoUnit.DAYS), "expired");
        final var expired = adapter.validateCertificate(expiredId, null, null, "example.test");
        assertFalse(expired.isSuccess());
        assertTrue(expired.getErrorMessage().contains("'expired'"), expired.getErrorMessage());
    }

    // ------------------------------------------------------------------ Cloudflare-managed certificates

    @Test
    void discoverySurfacesManagedPacksAsAssets() {
        server.seed(List.of("shop.example.test"), Instant.now().plus(300, ChronoUnit.DAYS), "active");
        final var universal = server.seedPack("universal", List.of("example.test", "*.example.test"), Instant.now().plus(60, ChronoUnit.DAYS), "active", "google");
        final var advanced = server.seedPack("advanced", List.of("api.example.test", "example.test"), Instant.now().plus(80, ChronoUnit.DAYS), "pending_validation", "lets_encrypt");
        server.seedPack("sni_custom", List.of("shop.example.test"), Instant.now().plus(300, ChronoUnit.DAYS), "active", null); // mirrors the custom one: must be skipped
        server.seedPack("advanced", List.of("old.example.test"), Instant.now().minus(1, ChronoUnit.DAYS), "deleted", "google");

        final var data = new CloudflareAdapter(config().build()).getConfigurationData();
        assertTrue(data.isSuccess(), data.getErrorMessage());
        assertEquals(1, data.getValue().getCertificates().size());
        final var managed = data.getValue().getManagedCertificates();
        assertEquals(2, managed.size());
        assertEquals(3, data.getValue().allCertificates().size());
        assertEquals(Boolean.TRUE, data.getValue().getUniversalSslEnabled());
        assertEquals(Boolean.FALSE, data.getValue().getTotalTlsEnabled());

        final var u = managed.get(0);
        assertTrue(u.isManaged());
        assertEquals(CloudflareCertificate.managedId(universal), u.getId());
        assertEquals(universal, u.packId());
        assertEquals("universal", u.getPackType());
        assertTrue(u.isUniversal());
        assertEquals("google", u.getCertificateAuthority());
        assertEquals(List.of("example.test", "*.example.test"), u.getHosts());
        assertEquals("example.test", u.primaryHost());
        assertNotNull(u.getExpiresOnEpoch());
        assertEquals(2, u.getPackExpiresOnEpochs().size());           // ECDSA + RSA certificate
        assertTrue(u.matchesExpiry(u.getPackExpiresOnEpochs().get(1))); // the edge may serve either
        assertTrue(u.isActive());
        assertTrue(server.requests.stream().anyMatch(r -> r.contains("/ssl/certificate_packs?status=all&page=1&per_page=50")));

        final var a = managed.get(1);
        assertEquals(CloudflareCertificate.managedId(advanced), a.getId());
        assertEquals("advanced", a.getPackType());
        assertFalse(a.isUniversal());
        assertFalse(a.isActive());
        assertEquals("Let's Encrypt", a.getIssuer());

        // 'ignore' lists custom certificates only and never calls the pack endpoints
        server.requests.clear();
        final var ignored = new CloudflareAdapter(config().managedMode(AdapterConfig.MANAGED_IGNORE).build()).getConfigurationData();
        assertTrue(ignored.isSuccess());
        assertTrue(ignored.getValue().getManagedCertificates().isEmpty());
        assertFalse(server.requests.stream().anyMatch(r -> r.contains("/ssl/")));
    }

    @Test
    void testConnectionReportsManagedPacksWithoutFailing() {
        server.seedPack("universal", List.of("example.test", "*.example.test"), Instant.now().plus(60, ChronoUnit.DAYS), "active", "google");
        final var result = new CloudflareAdapter(config().build()).testConnection();
        assertTrue(result.isSuccess(), result.getErrorMessage());
        assertTrue(server.requests.stream().anyMatch(r -> r.contains("/ssl/certificate_packs")));
        assertTrue(server.requests.stream().anyMatch(r -> r.equals("GET " + ZP + "/ssl/universal/settings")));
    }

    @Test
    void switchingFromUniversalUploadsCustomAndDisablesUniversalWhenFullyCovered() throws Exception {
        final var packId = server.seedPack("universal", List.of("example.test", "*.example.test"), Instant.now().plus(60, ChronoUnit.DAYS), "active", "google");
        final var managedId = CloudflareCertificate.managedId(packId);
        final var issued = TestCerts.selfSigned("example.test", List.of("example.test", "*.example.test"), Instant.now().plus(390, ChronoUnit.DAYS));
        final var adapter = new CloudflareAdapter(config().managedMode(AdapterConfig.MANAGED_DISCOVER_RETIRE).build());

        // the resolver reports the managed id separately; the install never receives it as a custom target
        final var result = adapter.installCertificate(issued.pem(), issued.keyPem(), null, issued.certificate(), List.of());
        assertTrue(result.isSuccess(), result.getErrorMessage());
        final var installed = result.getValue();
        assertEquals("upload", installed.getAction());
        assertEquals("active", installed.getStatus());
        assertEquals(1, server.certificates.size());

        adapter.retireManagedCertificates(List.of(managedId), issued.certificate(), installed);
        assertEquals(List.of(managedId), installed.getRetiredManaged());
        assertTrue(installed.getRetainedManaged().isEmpty());
        assertTrue(installed.getPendingManagedRetirements().isEmpty());
        assertTrue(installed.isUniversalSslDisabled());
        assertFalse(server.universalEnabled);
        assertTrue(server.packs.isEmpty());
        assertTrue(server.requests.stream().anyMatch(r -> r.equals("PATCH " + ZP + "/ssl/universal/settings")));
        assertFalse(server.requests.stream().anyMatch(r -> r.startsWith("DELETE") && r.contains("/custom_certificates/")));
        assertFalse(server.requests.stream().anyMatch(r -> r.startsWith("DELETE") && r.contains("/ssl/certificate_packs/")));
        assertTrue(server.requests.stream().anyMatch(r -> r.equals("GET " + ZP + "/acm/total_tls")));
    }

    @Test
    void universalIsKeptWhenTheCustomCertificateDoesNotCoverAllItsHosts() throws Exception {
        final var packId = server.seedPack("universal", List.of("example.test", "*.example.test"), Instant.now().plus(60, ChronoUnit.DAYS), "active", "google");
        final var managedId = CloudflareCertificate.managedId(packId);
        final var issued = TestCerts.selfSigned("www.example.test", List.of("www.example.test", "example.test"), Instant.now().plus(390, ChronoUnit.DAYS));
        final var adapter = new CloudflareAdapter(config().managedMode(AdapterConfig.MANAGED_DISCOVER_RETIRE).build());
        final var installed = adapter.installCertificate(issued.pem(), issued.keyPem(), null, issued.certificate(), List.of()).getValue();

        adapter.retireManagedCertificates(List.of(managedId), issued.certificate(), installed);
        assertEquals(List.of(managedId), installed.getRetainedManaged());   // *.example.test is not covered
        assertTrue(installed.getRetiredManaged().isEmpty());
        assertFalse(installed.isUniversalSslDisabled());
        assertTrue(server.universalEnabled);
        assertEquals(1, server.packs.size());
        assertFalse(server.requests.stream().anyMatch(r -> r.startsWith("PATCH " + ZP + "/ssl/universal/settings")));
    }

    @Test
    void switchingFromAdvancedDeletesThePack() throws Exception {
        final var packId = server.seedPack("advanced", List.of("api.example.test"), Instant.now().plus(80, ChronoUnit.DAYS), "active", "google");
        final var other = server.seedPack("advanced", List.of("other.example.test"), Instant.now().plus(80, ChronoUnit.DAYS), "active", "google");
        final var managedId = CloudflareCertificate.managedId(packId);
        final var issued = TestCerts.selfSigned("api.example.test", List.of("api.example.test"), Instant.now().plus(390, ChronoUnit.DAYS));
        final var adapter = new CloudflareAdapter(config().managedMode(AdapterConfig.MANAGED_DISCOVER_RETIRE).build());
        final var installed = adapter.installCertificate(issued.pem(), issued.keyPem(), null, issued.certificate(), List.of()).getValue();

        server.totalTlsEnabled = true; // only a warning
        adapter.retireManagedCertificates(List.of(managedId), issued.certificate(), installed);
        assertEquals(List.of(managedId), installed.getRetiredManaged());
        assertFalse(installed.isUniversalSslDisabled());
        assertTrue(server.universalEnabled);
        assertFalse(server.packs.containsKey(packId));
        assertTrue(server.packs.containsKey(other));
        assertTrue(server.requests.stream().anyMatch(r -> r.equals("DELETE " + ZP + "/ssl/certificate_packs/" + packId)));

        // a refused delete leaves the pack retained, never failed
        server.rejectPackDelete = true;
        final var second = new CloudflareInstalledCertificate();
        second.setCertificateId(installed.getCertificateId());
        second.setStatus("active");
        adapter.retireManagedCertificates(List.of(CloudflareCertificate.managedId(other)), issued.certificate(), second);
        assertEquals(List.of(CloudflareCertificate.managedId(other)), second.getRetainedManaged());
        assertTrue(server.packs.containsKey(other));
    }

    @Test
    void keepModeNeverTouchesManagedCertificates() throws Exception {
        final var packId = server.seedPack("universal", List.of("example.test", "*.example.test"), Instant.now().plus(60, ChronoUnit.DAYS), "active", "google");
        final var managedId = CloudflareCertificate.managedId(packId);
        final var issued = TestCerts.selfSigned("example.test", List.of("example.test", "*.example.test"), Instant.now().plus(390, ChronoUnit.DAYS));
        final var adapter = new CloudflareAdapter(config().build()); // discover_keep
        final var installed = adapter.installCertificate(issued.pem(), issued.keyPem(), null, issued.certificate(), List.of()).getValue();
        adapter.retireManagedCertificates(List.of(managedId), issued.certificate(), installed);
        assertEquals(List.of(managedId), installed.getRetainedManaged());
        assertTrue(installed.getRetiredManaged().isEmpty());
        assertTrue(server.universalEnabled);
        assertEquals(1, server.packs.size());
        assertFalse(server.requests.stream().anyMatch(r -> r.startsWith("PATCH") || (r.startsWith("DELETE") && r.contains("/ssl/"))));
    }

    @Test
    void retirementIsDeferredWhileTheCustomCertificateIsPending() throws Exception {
        final var packId = server.seedPack("universal", List.of("example.test", "*.example.test"), Instant.now().plus(60, ChronoUnit.DAYS), "active", "google");
        final var managedId = CloudflareCertificate.managedId(packId);
        final var issued = TestCerts.selfSigned("example.test", List.of("example.test", "*.example.test"), Instant.now().plus(390, ChronoUnit.DAYS));
        final var adapter = new CloudflareAdapter(config().managedMode(AdapterConfig.MANAGED_DISCOVER_RETIRE).build());
        final var pending = new CloudflareInstalledCertificate();
        pending.setCertificateId("abc");
        pending.setStatus("pending");
        adapter.retireManagedCertificates(List.of(managedId), issued.certificate(), pending);
        assertEquals(List.of(managedId), pending.getPendingManagedRetirements());
        assertTrue(pending.getRetiredManaged().isEmpty());
        assertTrue(server.universalEnabled);

        // validateCertificate retries once active
        pending.setStatus("active");
        pending.getPendingManagedRetirements().clear();
        adapter.retireManagedCertificates(List.of(managedId), issued.certificate(), pending);
        assertEquals(List.of(managedId), pending.getRetiredManaged());
        assertFalse(server.universalEnabled);

        // a managed id that no longer exists counts as retired
        final var gone = new CloudflareInstalledCertificate();
        gone.setStatus("active");
        adapter.retireManagedCertificates(List.of(managedId), issued.certificate(), gone);
        assertEquals(List.of(managedId), gone.getRetiredManaged());
    }

    @Test
    void installNeverRotatesAManagedIdThroughCustomCertificates() throws Exception {
        final var packId = server.seedPack("advanced", List.of("api.example.test"), Instant.now().plus(80, ChronoUnit.DAYS), "active", "google");
        final var issued = TestCerts.selfSigned("api.example.test", List.of("api.example.test"), Instant.now().plus(390, ChronoUnit.DAYS));
        final var adapter = new CloudflareAdapter(config().renewalStrategy(AdapterConfig.STRATEGY_REPLACE_DELETE).build());
        final var result = adapter.installCertificate(issued.pem(), issued.keyPem(), null, issued.certificate(),
                List.of(CloudflareCertificate.managedId(packId)));
        assertTrue(result.isSuccess(), result.getErrorMessage());
        assertEquals("upload", result.getValue().getAction());
        assertTrue(result.getValue().getDeletedCertificates().isEmpty());
        assertTrue(server.packs.containsKey(packId));
        assertFalse(server.requests.stream().anyMatch(r -> r.contains("/custom_certificates/pack-")));
        assertFalse(server.requests.stream().anyMatch(r -> r.startsWith("PATCH")));
    }
}
