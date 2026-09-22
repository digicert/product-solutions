package com.digicert.automation.f5xc.service.api;

import com.digicert.automation.F5XCAutomationPlugin;
import com.digicert.automation.extended.configuration.F5XCPluginConfiguration;
import com.digicert.automation.f5xc.service.api.response.CertificateListResponse;
import com.digicert.automation.f5xc.service.api.response.CertificateObject;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.node.ObjectNode;
import lombok.extern.slf4j.Slf4j;

import java.net.http.HttpResponse;
import java.util.List;

/**
 * Adapter for F5 Distributed Cloud (F5-XC) certificate-object operations.
 * <p>
 * All operations target {@code /api/config/namespaces/{namespace}/certificates}. A certificate
 * object carries the served certificate (chain) in {@code spec.certificate_url} and the
 * (write-only) private key in {@code spec.private_key.clear_secret_info.url}, each encoded as
 * {@code string:///<base64>} — mirroring the manual deployment performed by {@code f5_xc-awr.sh}.
 *
 * @author michael.rudloff
 */
@Slf4j
public class F5XCApiAdapter {

    private static final String CERTIFICATES_API = "/api/config/namespaces/%s/certificates";
    private static final String CERTIFICATE_ITEM_API = "/api/config/namespaces/%s/certificates/%s";

    private F5XCApiAdapter() {
    }

    private static final class SingletonHolder {
        private static final F5XCApiAdapter INSTANCE = new F5XCApiAdapter();
    }

    public static F5XCApiAdapter getInstance() {
        return SingletonHolder.INSTANCE;
    }

    /** Lists certificate objects in the configured namespace; validates connectivity + auth. */
    public List<CertificateListResponse.Item> listCertificates(F5XCPluginConfiguration configuration) throws Exception {
        RestClient restClient = new RestClient(configuration);
        String endpoint = CERTIFICATES_API.formatted(configuration.getNamespace());

        HttpResponse<String> response = restClient.get(endpoint);
        restClient.validateHttpResponseStatus(response);

        CertificateListResponse listResponse = mapper().readValue(response.body(), CertificateListResponse.class);
        List<CertificateListResponse.Item> items = listResponse.getItems();
        log.info("Found {} certificate object(s) in namespace '{}'", items.size(), configuration.getNamespace());
        return items;
    }

    /** Fetches a single certificate object by name. */
    public CertificateObject getCertificate(F5XCPluginConfiguration configuration, String certificateName) throws Exception {
        RestClient restClient = new RestClient(configuration);
        String endpoint = CERTIFICATE_ITEM_API.formatted(configuration.getNamespace(), certificateName);

        HttpResponse<String> response = restClient.get(endpoint);
        restClient.validateHttpResponseStatus(response);
        return mapper().readValue(response.body(), CertificateObject.class);
    }

    /** Returns {@code true} when a certificate object with the given name exists (HTTP 200). */
    public boolean certificateExists(F5XCPluginConfiguration configuration, String certificateName) throws Exception {
        RestClient restClient = new RestClient(configuration);
        String endpoint = CERTIFICATE_ITEM_API.formatted(configuration.getNamespace(), certificateName);

        HttpResponse<String> response = restClient.get(endpoint);
        if (response.statusCode() == 404) {
            return false;
        }
        restClient.validateHttpResponseStatus(response);
        return true;
    }

    /**
     * Creates (POST) or replaces (PUT) the named certificate object with the supplied
     * Base64-encoded certificate (chain) PEM and private key PEM.
     */
    public void upsertCertificate(F5XCPluginConfiguration configuration,
                                  String certificateName,
                                  String certPemBase64,
                                  String keyPemBase64) throws Exception {
        RestClient restClient = new RestClient(configuration);
        String namespace = configuration.getNamespace();
        String payload = buildCertificatePayload(namespace, certificateName, certPemBase64, keyPemBase64);

        boolean exists = certificateExists(configuration, certificateName);
        HttpResponse<String> response;
        if (exists) {
            log.info("Certificate object '{}' exists in namespace '{}' - replacing (PUT)", certificateName, namespace);
            response = restClient.put(CERTIFICATE_ITEM_API.formatted(namespace, certificateName), payload);
        } else {
            log.info("Certificate object '{}' not found in namespace '{}' - creating (POST)", certificateName, namespace);
            response = restClient.post(CERTIFICATES_API.formatted(namespace), payload);
        }
        restClient.validateHttpResponseStatus(response);
    }

    /**
     * Builds the F5-XC certificate-object request body:
     * <pre>
     * {
     *   "metadata": { "name": "&lt;name&gt;", "namespace": "&lt;ns&gt;" },
     *   "spec": {
     *     "certificate_url": "string:///&lt;b64 cert&gt;",
     *     "private_key": { "clear_secret_info": { "url": "string:///&lt;b64 key&gt;" } }
     *   }
     * }
     * </pre>
     */
    String buildCertificatePayload(String namespace, String certificateName, String certPemBase64, String keyPemBase64)
            throws Exception {
        ObjectMapper mapper = mapper();
        ObjectNode root = mapper.createObjectNode();

        ObjectNode metadata = root.putObject("metadata");
        metadata.put("name", certificateName);
        metadata.put("namespace", namespace);

        ObjectNode spec = root.putObject("spec");
        spec.put("certificate_url", "string:///" + certPemBase64);
        spec.putObject("private_key")
                .putObject("clear_secret_info")
                .put("url", "string:///" + keyPemBase64);

        return mapper.writeValueAsString(root);
    }

    private static ObjectMapper mapper() {
        return F5XCAutomationPlugin.getObjectMapper();
    }
}
