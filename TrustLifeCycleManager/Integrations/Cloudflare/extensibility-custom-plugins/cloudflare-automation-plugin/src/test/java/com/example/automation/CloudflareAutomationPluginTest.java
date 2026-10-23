package com.example.automation;

import static org.junit.jupiter.api.Assertions.assertEquals;
import static org.junit.jupiter.api.Assertions.assertFalse;
import static org.junit.jupiter.api.Assertions.assertNotEquals;
import static org.junit.jupiter.api.Assertions.assertNull;
import static org.junit.jupiter.api.Assertions.assertTrue;

import java.nio.charset.StandardCharsets;
import java.time.Instant;
import java.time.temporal.ChronoUnit;
import java.util.Base64;
import java.util.List;
import java.util.Map;

import org.junit.jupiter.api.Test;

import com.example.automation.adapter.AdapterConfig;
import com.example.automation.adapter.CloudflareAdapter;
import com.example.automation.helper.CertificateAttributesUtil;
import com.example.automation.helper.CloudflareAutomationPluginHelper;
import com.example.automation.helper.ReplacementResolver;
import com.example.automation.model.CloudflareCertificate;

class CloudflareAutomationPluginTest {

    private static CloudflareCertificate cert(String id, List<String> hosts, long expiresEpoch) {
        final var c = new CloudflareCertificate();
        c.setId(id);
        c.setHosts(hosts);
        c.setStatus("active");
        c.setExpiresOnEpoch(expiresEpoch);
        return c;
    }

    @Test
    void endpointsAreStableAndUnique() {
        final var a = cert("aaaaaaaa-1111-2222-3333-444444444444", List.of("www.example.test", "example.test"), 2_000_000_000L);
        final var b = cert("bbbbbbbb-1111-2222-3333-444444444444", List.of("example.test", "www.example.test"), 1_900_000_000L);
        final var w = cert("cccccccc-1111-2222-3333-444444444444", List.of("*.example.test"), 1_800_000_000L);
        final var none = cert("dddddddd-1111-2222-3333-444444444444", List.of(), 1_700_000_000L);
        final var endpoints = CloudflareAutomationPlugin.assignEndpoints(List.of(b, a, w, none), "example.test");
        assertEquals("example.test", endpoints.get(a.getId()));          // newest owns the canonical host
        assertEquals("bbbbbbbb.example.test", endpoints.get(b.getId())); // duplicate falls back to id prefix
        assertEquals("wildcard.example.test", endpoints.get(w.getId()));
        assertEquals("cert-dddddddd.example.test", endpoints.get(none.getId()));
        assertEquals(4, endpoints.values().stream().distinct().count());
    }

    @Test
    void primaryHostPrefersCnThenShortestHost() {
        final var c = cert("x", List.of("api.example.test", "www.example.test", "example.test"), 1L);
        assertEquals("example.test", c.primaryHost());
        c.setCommonName("www.example.test");
        assertEquals("www.example.test", c.primaryHost());
    }

    @Test
    void decodeSecretKeepsRawCloudflareTokensAndDecodesBase64() {
        final var token = "v1.0-abcDEF_ghiJKL-mnoPQR_stuVWX-yz0123456789";
        assertEquals(token, CloudflareAutomationPlugin.decodeSecret(token));
        final var encoded = Base64.getEncoder().encodeToString(token.getBytes(StandardCharsets.UTF_8));
        assertEquals(token, CloudflareAutomationPlugin.decodeSecret(encoded));
        // 40 alphanumeric characters are valid base64 but decode to control bytes → used raw
        final var alnum = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmn";
        assertEquals(alnum, CloudflareAutomationPlugin.decodeSecret(alnum));
        assertNull(CloudflareAutomationPlugin.decodeSecret(null));
    }

    @Test
    void zoneIdNormalisation() {
        assertEquals("023e105f4ecef8ad9ca31a8372d0c353", AdapterConfig.normalizeZoneId(" Zone ID: 023e105f4ecef8ad9ca31a8372d0c353 "));
        assertTrue(AdapterConfig.looksLikeZoneId("023e105f4ecef8ad9ca31a8372d0c353"));
        assertFalse(AdapterConfig.looksLikeZoneId("example.com"));
        assertNull(AdapterConfig.normalizeZoneId("  "));
    }

    @Test
    void dnParsingAndHostMatching() {
        final var dn = CertificateAttributesUtil.parseDn("CN=www.example.test, OU=Web, O=Example Ltd, L=London, ST=Greater London, C=GB");
        assertEquals("www.example.test", dn.get("CN"));
        assertEquals("Greater London", dn.get("ST"));
        assertEquals("GB", dn.get("C"));
        assertEquals("Example Ltd", CertificateAttributesUtil.rdnValue("/C=GB/O=Example Ltd/CN=x", "O"));
        assertTrue(CertificateAttributesUtil.hostMatches("*.example.test", "www.example.test"));
        assertFalse(CertificateAttributesUtil.hostMatches("*.example.test", "a.b.example.test"));
        assertFalse(CertificateAttributesUtil.hostMatches("*.example.test", "example.test"));
        assertTrue(CertificateAttributesUtil.hostsCover(List.of("example.test", "*.example.test"), "Shop.Example.Test"));
        assertEquals(List.of("a.test", "b.test"), CertificateAttributesUtil.getDnsNames("a.test, b.test,a.test"));
    }

    @Test
    void epochParsingAcceptsCloudflareFormats() {
        assertEquals(1735689600L, CloudflareAutomationPluginHelper.parseEpochSeconds("2025-01-01T00:00:00Z"));
        assertEquals(1735689600L, CloudflareAutomationPluginHelper.parseEpochSeconds("2025-01-01T00:00:00.000000Z"));
        assertEquals(1735689600L, CloudflareAutomationPluginHelper.parseEpochSeconds("2025-01-01T01:00:00+01:00"));
        assertNull(CloudflareAutomationPluginHelper.parseEpochSeconds("soon"));
    }

    @Test
    void keyTypeMapping() {
        assertEquals("rsa2048", CloudflareAdapter.mapKeyType("RSA", "2048"));
        assertEquals("rsa2048", CloudflareAdapter.mapKeyType("RSA", "4096"));
        assertEquals("p256v1", CloudflareAdapter.mapKeyType("ECDSA", "256"));
        assertEquals("p256v1", CloudflareAdapter.mapKeyType("EC", "384"));
        assertEquals("rsa2048", CloudflareAdapter.mapKeyType(null, null));
    }

    @Test
    void resolverPrefersAliasThenThumbprintThenEndpointThenHosts() throws Exception {
        final var issued = TestCerts.selfSigned("www.example.test", List.of("www.example.test", "example.test"),
                Instant.now().plus(390, ChronoUnit.DAYS));
        final var old = TestCerts.selfSigned("www.example.test", List.of("www.example.test"), Instant.now().plus(10, ChronoUnit.DAYS));
        final var a = cert("id-a", List.of("www.example.test"), 1_900_000_000L);
        final var b = cert("id-b", List.of("*.example.test"), 2_000_000_000L);
        final var ecc = cert("id-ecc", List.of("www.example.test"), 2_100_000_000L);
        ecc.setKeyType("ecc");
        final var certs = List.of(a, b, ecc);
        final Map<String, String> endpoints = Map.of("id-a", "www.example.test", "id-b", "wildcard.example.test", "id-ecc", "id-ecc.www.example.test");

        var sel = ReplacementResolver.resolve(certs, Map::of, endpoints, null, "null/id-b", null, null, issued.certificate());
        assertEquals(List.of("id-b"), sel.ids());

        sel = ReplacementResolver.resolve(certs, Map::of, endpoints, "id-a", "null/id-b", null, null, issued.certificate());
        assertEquals(List.of("id-a"), sel.ids());

        final var thumb = CertificateAttributesUtil.fingerprintHex(old.certificate(), "SHA-256");
        sel = ReplacementResolver.resolve(certs, () -> Map.of("id-a", old.pem()), endpoints, null, "null/stale", thumb, null, issued.certificate());
        assertEquals(List.of("id-a"), sel.ids());
        assertTrue(sel.strategy().contains("thumbprint"));

        sel = ReplacementResolver.resolve(certs, Map::of, endpoints, null, "null/stale", "ABCD", "wildcard.example.test", issued.certificate());
        assertEquals(List.of("id-b"), sel.ids());

        sel = ReplacementResolver.resolve(certs, Map::of, endpoints, null, null, null, null, issued.certificate());
        assertEquals(List.of("id-b", "id-a"), sel.ids()); // hosts match, newest first, ECC skipped for an RSA leaf
        assertTrue(sel.strategy().contains("hosts"));

        sel = ReplacementResolver.resolve(List.of(), Map::of, Map.of(), null, "null/x", null, null, issued.certificate());
        assertTrue(sel.isEmpty());
        assertEquals("x", ReplacementResolver.stripPartition("Common/x"));
        assertNull(ReplacementResolver.stripPartition("null/null"));
    }

    @Test
    void servedCertificateMatchingUsesExpiryAndHosts() throws Exception {
        final var issued = TestCerts.selfSigned("www.example.test", List.of("www.example.test"), Instant.now().plus(390, ChronoUnit.DAYS));
        final var same = cert("x", List.of("www.example.test"), issued.certificate().getNotAfter().toInstant().getEpochSecond());
        assertTrue(CloudflareAdapter.servedMatches(same, issued.certificate()));
        final var otherExpiry = cert("y", List.of("www.example.test"), 1L);
        assertFalse(CloudflareAdapter.servedMatches(otherExpiry, issued.certificate()));
        final var otherHosts = cert("z", List.of("other.test"), issued.certificate().getNotAfter().toInstant().getEpochSecond());
        assertFalse(CloudflareAdapter.servedMatches(otherHosts, issued.certificate()));
        final var wildcard = cert("w", List.of("*.example.test"), issued.certificate().getNotAfter().toInstant().getEpochSecond());
        assertTrue(CloudflareAdapter.servedMatches(wildcard, issued.certificate()));

        final var c = cert("p", List.of("www.example.test"), 1L);
        c.setCertificatePem(issued.pem());
        CloudflareAdapter.applyPem(c);
        assertEquals("www.example.test", c.getCommonName());
        assertEquals("rsa", c.getKeyType());
        assertEquals(64, c.getFingerprintSha256().length());
        assertNotEquals(null, c.getSerialNumber());
    }

    @Test
    void probeCandidatesPreferPrimaryHostAndCoverWildcards() {
        final var c = cert("x", List.of("api.example.test", "example.test", "*.example.test"), 1L);
        final var candidates = CloudflareAdapter.probeCandidates(c, "example.test");
        assertEquals("example.test", candidates.get(0)[0]);
        assertEquals("example.test", candidates.get(0)[1]);
        assertTrue(candidates.stream().anyMatch(p -> p[0].equals("example.test") && p[1].equals("api.example.test")));
        assertTrue(candidates.stream().anyMatch(p -> p[1].equals("www.example.test")));
        assertTrue(candidates.size() <= 8);
    }
}
