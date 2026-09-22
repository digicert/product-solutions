package com.digicert.automation.f5xc.service;

import com.digicert.automation.extended.configuration.F5XCPluginConfiguration;
import com.digicert.automation.f5xc.service.api.F5XCApiAdapter;
import com.digicert.automation.f5xc.service.api.NetworkApiAdapter;
import com.digicert.automation.f5xc.service.api.RestClient;
import com.digicert.automation.f5xc.service.api.response.CertificateListResponse;
import com.digicert.automation.f5xc.service.api.response.CertificateObject;
import com.digicert.automation.helper.AutomationPluginHelper;
import com.digicert.tlm.plugin.PluginError;
import com.digicert.tlm.workflows.automation.dto.RefreshConfigurationResponse;
import com.fasterxml.jackson.databind.JsonNode;
import lombok.extern.slf4j.Slf4j;

import java.security.cert.X509Certificate;
import java.util.ArrayList;
import java.util.List;
import java.util.Optional;

/**
 * Discovers F5-XC certificate objects in the configured namespace and maps them onto the TLM
 * discovery model.
 * <p>
 * Each certificate object becomes one {@code DataIpInfo} + {@code Certificate} entry. The object
 * name is the stable identifier: TLM forms {@code virtualServerName = <partition>/<alias> =
 * <namespace>/<certName>}, which {@code installCertificate} and {@code validateCertificate}
 * split back to address the same object.
 *
 * @author michael.rudloff
 */
@Slf4j
public final class RefreshConfigurationService {

    private RefreshConfigurationService() {
    }

    private static final class SingletonHolder {
        private static final RefreshConfigurationService INSTANCE = new RefreshConfigurationService();
    }

    public static RefreshConfigurationService getInstance() {
        return SingletonHolder.INSTANCE;
    }

    public RefreshConfigurationResponse<JsonNode> refreshConfiguration(F5XCPluginConfiguration pluginConfiguration) {
        RefreshConfigurationResponse<JsonNode> response = new RefreshConfigurationResponse<>();
        try {
            String baseUrl = new RestClient(pluginConfiguration).getBaseUrl();
            List<CertificateListResponse.Item> items = F5XCApiAdapter.getInstance().listCertificates(pluginConfiguration);
            buildResponse(pluginConfiguration, baseUrl, response, items);
            log.info("refresh configuration successful");
        } catch (Exception e) {
            String errorMessage = "Failed to get configurations from F5-XC API. " + e.getMessage();
            log.error(errorMessage, e);
            response.setErrors(List.of(new PluginError("REFRESH_CONFIGURATION_FAILURE", errorMessage)));
        }
        return response;
    }

    private void buildResponse(F5XCPluginConfiguration configuration,
                               String baseUrl,
                               RefreshConfigurationResponse<JsonNode> response,
                               List<CertificateListResponse.Item> items) {
        RefreshConfigurationResponse.AutomationInfo automationInfo = buildAutomationInfo(configuration, baseUrl);
        List<RefreshConfigurationResponse.DataIpInfo> dataIpInfos = new ArrayList<>();
        List<RefreshConfigurationResponse.Certificate> certificateDetails = new ArrayList<>();

        for (CertificateListResponse.Item item : items) {
            Optional<CertificatePair> pair = buildCertificatePair(configuration, automationInfo, item.getName());
            pair.ifPresent(p -> {
                dataIpInfos.add(p.dataIpInfo());
                certificateDetails.add(p.certificate());
            });
        }

        automationInfo.setDataIps(dataIpInfos.stream()
                .map(RefreshConfigurationResponse.DataIpInfo::getDataIp)
                .filter(ip -> ip != null && !ip.isBlank())
                .distinct().toArray(String[]::new));
        response.setAutomationInfo(automationInfo);
        response.setDataIpInfo(dataIpInfos);
        response.setCertificates(certificateDetails);
    }

    private Optional<CertificatePair> buildCertificatePair(F5XCPluginConfiguration configuration,
                                                           RefreshConfigurationResponse.AutomationInfo automationInfo,
                                                           String certName) {
        try {
            CertificateObject object = F5XCApiAdapter.getInstance().getCertificate(configuration, certName);
            String pem = object.getSpec() == null ? "" : AutomationPluginHelper.decodeF5XCCertificateUrl(object.getSpec().getCertificateUrl());
            if (pem.isBlank()) {
                log.warn("Certificate object '{}' has no inline certificate_url (managed/auto-cert?) - skipping", certName);
                return Optional.empty();
            }

            X509Certificate x509 = AutomationPluginHelper.parseFirstCertificate(pem);
            String commonName = AutomationPluginHelper.getCommonName(x509);

            // F5-XC certificate objects are API-managed resources with no per-object IP endpoint.
            // TLM keys the endpoint on ipAddress:port, so resolving every object's CN to the shared
            // LB VIP collapses all objects behind that VIP — and any sharing a CN — into one endpoint,
            // letting a renewal target the wrong/stale object. Use the F5-XC object name as the
            // endpoint address instead: it is unique and stable within the namespace, so each object
            // is its own endpoint and renewals always target the right object. The object's CN is
            // still reported in domainName, and namespace/certName remains the virtualServerName that
            // install/validate consume.
            String endpointAddress = certName;
            String location = endpointAddress + ":443";

            RefreshConfigurationResponse.DataIpInfo dataIpInfo = new RefreshConfigurationResponse.DataIpInfo();
            dataIpInfo.setManagementIp(automationInfo.getManagementIp());
            dataIpInfo.setDataIp(endpointAddress);
            dataIpInfo.setPort(443);
            dataIpInfo.setSslState(1);
            dataIpInfo.setPartition(configuration.getNamespace());
            dataIpInfo.setAlias(certName);
            dataIpInfo.setPortWithCert("443:" + certName);

            RefreshConfigurationResponse.Certificate certificate = new RefreshConfigurationResponse.Certificate();
            certificate.setIpAddress(endpointAddress);
            certificate.setPort(443);
            certificate.setDomainName(commonName);
            certificate.setIpAndPort(location);
            certificate.setServerParam(certName);
            certificate.setCertificate(pem);
            certificate.setSni(false);
            certificate.setCipherDiscovery(null);

            return Optional.of(new CertificatePair(dataIpInfo, certificate));
        } catch (Exception e) {
            log.warn("Failed to read certificate object '{}': {}", certName, e.getMessage());
            return Optional.empty();
        }
    }

    private RefreshConfigurationResponse.AutomationInfo buildAutomationInfo(F5XCPluginConfiguration configuration, String baseUrl) {
        RefreshConfigurationResponse.AutomationInfo automationInfo = new RefreshConfigurationResponse.AutomationInfo();
        automationInfo.setManagementIp(NetworkApiAdapter.getIp(baseUrl));
        automationInfo.setHostName(NetworkApiAdapter.getHostname(baseUrl));
        automationInfo.setOsName("NA");
        automationInfo.setOsVersion("NA");
        automationInfo.setOsArch("NA");
        automationInfo.setOsFlavor("NA");
        automationInfo.setFips("disabled");
        automationInfo.setPeerInfo(automationInfo.getManagementIp() + ":PRIMARY");
        automationInfo.setPartitions(new String[] {configuration.getNamespace()});
        return automationInfo;
    }

    /** Pairs a discovered {@code DataIpInfo} with its {@code Certificate}. */
    private record CertificatePair(RefreshConfigurationResponse.DataIpInfo dataIpInfo,
                                   RefreshConfigurationResponse.Certificate certificate) {
    }
}
