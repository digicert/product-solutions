package com.example.automation;

import java.io.IOException;
import java.io.OutputStream;
import java.net.InetSocketAddress;
import java.nio.charset.StandardCharsets;
import java.time.Instant;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.UUID;
import java.util.concurrent.atomic.AtomicInteger;

import com.example.automation.helper.CertificateAttributesUtil;
import com.example.automation.helper.CloudflareAutomationPluginHelper;
import com.fasterxml.jackson.databind.JsonNode;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.node.ArrayNode;
import com.fasterxml.jackson.databind.node.ObjectNode;
import com.sun.net.httpserver.HttpExchange;
import com.sun.net.httpserver.HttpServer;

/**
 * Minimal in-memory imitation of the Cloudflare v4 endpoints the plugin uses. Uploaded
 * certificates are parsed so {@code hosts} and {@code expires_on} are derived like Cloudflare does.
 */
public class MockCloudflareServer implements AutoCloseable {

    public static final String ZONE_ID = "023e105f4ecef8ad9ca31a8372d0c353";
    public static final String TOKEN = "v1.0-test-token_ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-abc";

    private static final ObjectMapper MAPPER = new ObjectMapper();

    private final HttpServer server;
    public final Map<String, ObjectNode> certificates = new LinkedHashMap<>();
    public final Map<String, ObjectNode> csrs = new LinkedHashMap<>();
    public final List<String> requests = new ArrayList<>();
    public final AtomicInteger pendingReadsBeforeActive = new AtomicInteger(0);
    public boolean rejectPatch;
    public int tokenStatusCode = 200;

    public MockCloudflareServer() throws IOException {
        server = HttpServer.create(new InetSocketAddress("127.0.0.1", 0), 0);
        server.createContext("/", this::handle);
        server.start();
    }

    public String baseUrl() {
        return "http://127.0.0.1:" + server.getAddress().getPort() + "/client/v4";
    }

    @Override
    public void close() {
        server.stop(0);
    }

    /** Seeds a certificate entry straight from metadata (no PEM involved). */
    public String seed(List<String> hosts, Instant expiresOn, String status) {
        final var id = UUID.randomUUID().toString();
        final var n = MAPPER.createObjectNode();
        n.put("id", id);
        n.put("zone_id", ZONE_ID);
        final ArrayNode h = n.putArray("hosts");
        hosts.forEach(h::add);
        n.put("issuer", "DigiCert");
        n.put("signature", "SHA256WithRSA");
        n.put("status", status);
        n.put("bundle_method", "force");
        n.put("type", "sni_custom");
        n.put("priority", certificates.size() + 1);
        n.put("expires_on", expiresOn.toString());
        n.put("uploaded_on", Instant.now().toString());
        n.put("modified_on", Instant.now().toString());
        certificates.put(id, n);
        return id;
    }

    private void handle(HttpExchange ex) throws IOException {
        final var method = ex.getRequestMethod();
        final var path = ex.getRequestURI().getPath().replace("/client/v4", "");
        final var query = ex.getRequestURI().getQuery();
        requests.add(method + " " + path + (query == null ? "" : "?" + query));
        final var body = new String(ex.getRequestBody().readAllBytes(), StandardCharsets.UTF_8);
        try {
            final var auth = ex.getRequestHeaders().getFirst("Authorization");
            if (!("Bearer " + TOKEN).equals(auth)) {
                error(ex, 400, 10000, "Authentication error");
                return;
            }
            if (path.equals("/user/tokens/verify")) {
                if (tokenStatusCode != 200) {
                    error(ex, tokenStatusCode, 9109, "Invalid access token");
                    return;
                }
                final var r = MAPPER.createObjectNode();
                r.put("id", "tok123");
                r.put("status", "active");
                ok(ex, r, null);
                return;
            }
            final var zonePrefix = "/zones/" + ZONE_ID;
            if (!path.startsWith(zonePrefix)) {
                error(ex, 404, 7003, "No route for the URI");
                return;
            }
            final var rest = path.substring(zonePrefix.length());
            if (rest.isEmpty()) {
                final var z = MAPPER.createObjectNode();
                z.put("id", ZONE_ID);
                z.put("name", "example.test");
                z.put("status", "active");
                z.put("type", "full");
                z.put("paused", false);
                z.putObject("account").put("id", "acc1").put("name", "Test Account");
                z.putObject("plan").put("name", "Enterprise Website");
                ok(ex, z, null);
                return;
            }
            if (rest.equals("/custom_certificates")) {
                if (method.equals("GET")) {
                    page(ex, new ArrayList<>(certificates.values()), query);
                } else if (method.equals("POST")) {
                    final var req = MAPPER.readTree(body);
                    final var c = fromUpload(req, UUID.randomUUID().toString());
                    if (c == null) {
                        error(ex, 400, 1002, "Invalid certificate");
                        return;
                    }
                    c.put("priority", certificates.size() + 1);
                    certificates.put(c.get("id").asText(), c);
                    ok(ex, c, null);
                } else {
                    error(ex, 405, 7003, "Method not allowed");
                }
                return;
            }
            if (rest.startsWith("/custom_certificates/")) {
                final var id = rest.substring("/custom_certificates/".length());
                final var existing = certificates.get(id);
                if (existing == null) {
                    // Live behaviour (2026-10-12): HTTP 400 code 1002 "Invalid certificate", not 404.
                    error(ex, 400, 1002, "Invalid certificate");
                    return;
                }
                switch (method) {
                    case "GET" -> {
                        if (pendingReadsBeforeActive.get() > 0 && "pending".equals(existing.path("status").asText())) {
                            if (pendingReadsBeforeActive.decrementAndGet() == 0) {
                                existing.put("status", "active");
                            }
                        }
                        ok(ex, existing, null);
                    }
                    case "PATCH" -> {
                        if (rejectPatch) {
                            error(ex, 400, 1004, "Custom certificate update is not permitted");
                            return;
                        }
                        // Live behaviour (2026-10-12): the PATCH answers with a NEW id and the old record
                        // disappears immediately (GET on it → 400 code 1002).
                        final var req = MAPPER.readTree(body);
                        final var newId = UUID.randomUUID().toString();
                        final var c = fromUpload(req, newId);
                        if (c == null) {
                            error(ex, 400, 1002, "Invalid certificate");
                            return;
                        }
                        c.put("priority", existing.path("priority").asInt());
                        c.put("uploaded_on", existing.path("uploaded_on").asText());
                        certificates.remove(id);
                        certificates.put(newId, c);
                        ok(ex, c, null);
                    }
                    case "DELETE" -> {
                        certificates.remove(id);
                        ok(ex, MAPPER.createObjectNode().put("id", id), null);
                    }
                    default -> error(ex, 405, 7003, "Method not allowed");
                }
                return;
            }
            if (rest.equals("/custom_csrs")) {
                if (method.equals("GET")) {
                    page(ex, new ArrayList<>(csrs.values()), query);
                } else if (method.equals("POST")) {
                    final var req = MAPPER.readTree(body);
                    for (String required : List.of("country", "state", "locality", "organization", "common_name", "sans")) {
                        if (!req.hasNonNull(required)) {
                            error(ex, 400, 1001, "Missing required field " + required);
                            return;
                        }
                    }
                    final var keyType = req.path("key_type").asText("rsa2048");
                    if (!keyType.equals("rsa2048") && !keyType.equals("p256v1")) {
                        error(ex, 400, 1001, "Invalid key_type");
                        return;
                    }
                    final var c = MAPPER.createObjectNode();
                    final var id = UUID.randomUUID().toString();
                    c.put("id", id);
                    c.setAll((ObjectNode) req);
                    c.put("key_type", keyType);
                    c.put("created_at", Instant.now().plusSeconds(csrs.size()).toString());
                    c.put("csr", "-----BEGIN CERTIFICATE REQUEST-----\nMIIC" + id.replace("-", "") + "\n-----END CERTIFICATE REQUEST-----\n");
                    csrs.put(id, c);
                    ok(ex, 201, c, null); // live Cloudflare answers 201 Created here
                } else {
                    error(ex, 405, 7003, "Method not allowed");
                }
                return;
            }
            if (rest.startsWith("/custom_csrs/")) {
                final var id = rest.substring("/custom_csrs/".length());
                if (!csrs.containsKey(id)) {
                    error(ex, 404, 1000, "CSR not found");
                    return;
                }
                if (method.equals("DELETE")) {
                    csrs.remove(id);
                    ok(ex, MAPPER.createObjectNode().put("id", id), null);
                } else {
                    ok(ex, csrs.get(id), null);
                }
                return;
            }
            error(ex, 404, 7003, "No route for the URI");
        } catch (Exception e) {
            error(ex, 500, 1, "mock failure: " + e);
        }
    }

    /** Builds the certificate entry Cloudflare would store for an upload / update body. */
    private ObjectNode fromUpload(JsonNode req, String id) {
        try {
            final var pem = req.path("certificate").asText(null);
            if (pem == null || !pem.contains("-----BEGIN CERTIFICATE-----")) {
                return null;
            }
            final boolean hasKey = req.hasNonNull("private_key") || (req.hasNonNull("custom_csr_id") && csrs.containsKey(req.path("custom_csr_id").asText()));
            if (!hasKey) {
                return null;
            }
            final var x = CloudflareAutomationPluginHelper.parseFirstCertificate(pem);
            final var c = MAPPER.createObjectNode();
            c.put("id", id);
            c.put("zone_id", ZONE_ID);
            final ArrayNode h = c.putArray("hosts");
            CertificateAttributesUtil.coveredNames(x).forEach(h::add);
            c.put("issuer", "Test");
            c.put("signature", x.getSigAlgName());
            c.put("status", "pending");
            c.put("bundle_method", req.path("bundle_method").asText("ubiquitous"));
            c.put("type", req.path("type").asText("sni_custom"));
            if (req.hasNonNull("custom_csr_id")) {
                c.put("custom_csr_id", req.path("custom_csr_id").asText());
            }
            c.put("expires_on", x.getNotAfter().toInstant().toString());
            c.put("uploaded_on", Instant.now().toString());
            c.put("modified_on", Instant.now().toString());
            if (pendingReadsBeforeActive.get() <= 0) {
                c.put("status", "active");
            }
            return c;
        } catch (Exception e) {
            return null;
        }
    }

    private void page(HttpExchange ex, List<ObjectNode> all, String query) throws IOException {
        int page = 1;
        int perPage = 20;
        if (query != null) {
            for (String kv : query.split("&")) {
                final var parts = kv.split("=", 2);
                if (parts.length == 2 && parts[0].equals("page")) {
                    page = Integer.parseInt(parts[1]);
                }
                if (parts.length == 2 && parts[0].equals("per_page")) {
                    perPage = Integer.parseInt(parts[1]);
                }
            }
        }
        final int from = Math.min(all.size(), (page - 1) * perPage);
        final int to = Math.min(all.size(), from + perPage);
        final ArrayNode result = MAPPER.createArrayNode();
        all.subList(from, to).forEach(result::add);
        final var info = MAPPER.createObjectNode();
        info.put("page", page);
        info.put("per_page", perPage);
        info.put("count", to - from);
        info.put("total_count", all.size());
        info.put("total_pages", Math.max(1, (all.size() + perPage - 1) / perPage));
        ok(ex, result, info);
    }

    private static void ok(HttpExchange ex, JsonNode result, ObjectNode resultInfo) throws IOException {
        ok(ex, 200, result, resultInfo);
    }

    private static void ok(HttpExchange ex, int status, JsonNode result, ObjectNode resultInfo) throws IOException {
        final var env = MAPPER.createObjectNode();
        env.put("success", true);
        env.putArray("errors");
        env.putArray("messages");
        env.set("result", result);
        if (resultInfo != null) {
            env.set("result_info", resultInfo);
        }
        write(ex, status, env);
    }

    private static void error(HttpExchange ex, int status, int code, String message) throws IOException {
        final var env = MAPPER.createObjectNode();
        env.put("success", false);
        env.putArray("errors").addObject().put("code", code).put("message", message);
        env.putArray("messages");
        env.putNull("result");
        write(ex, status, env);
    }

    private static void write(HttpExchange ex, int status, JsonNode body) throws IOException {
        final byte[] bytes = MAPPER.writeValueAsBytes(body);
        ex.getResponseHeaders().add("Content-Type", "application/json");
        ex.sendResponseHeaders(status, bytes.length);
        try (OutputStream os = ex.getResponseBody()) {
            os.write(bytes);
        }
    }
}
