package com.digicert.automation.f5xc.service;

import com.digicert.automation.extended.configuration.F5XCPluginConfiguration;
import com.digicert.automation.f5xc.service.api.F5XCApiAdapter;
import com.digicert.tlm.plugin.PluginError;
import com.digicert.tlm.plugin.Response;
import com.digicert.tlm.workflows.automation.dto.TestConnectionResponse;
import com.fasterxml.jackson.databind.JsonNode;
import lombok.extern.slf4j.Slf4j;

import java.util.List;

/**
 * Tests connectivity and authentication against the F5-XC API by listing the certificate
 * objects in the configured namespace.
 *
 * @author michael.rudloff
 */
@Slf4j
public final class TestConnectionService {

    private TestConnectionService() {
    }

    private static final class SingletonHolder {
        private static final TestConnectionService INSTANCE = new TestConnectionService();
    }

    public static TestConnectionService getInstance() {
        return SingletonHolder.INSTANCE;
    }

    public Response<JsonNode> testConnection(F5XCPluginConfiguration pluginConfiguration) {
        TestConnectionResponse<JsonNode> response = new TestConnectionResponse<>();
        try {
            F5XCApiAdapter.getInstance().listCertificates(pluginConfiguration);
            response.setActive(true);
            log.info("test connection is successful");
        } catch (Exception e) {
            String errorMessage = "Failed to connect to F5-XC API. " + e.getMessage();
            log.error(errorMessage, e);
            response.setActive(false);
            response.setErrors(List.of(new PluginError("TEST_CONNECTION_FAILURE", errorMessage)));
        }
        return response;
    }
}
