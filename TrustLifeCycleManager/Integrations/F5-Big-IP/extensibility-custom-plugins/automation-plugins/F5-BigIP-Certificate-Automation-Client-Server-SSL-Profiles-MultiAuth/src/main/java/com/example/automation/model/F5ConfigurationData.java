package com.example.automation.model;

import java.util.ArrayList;
import java.util.List;

import com.fasterxml.jackson.annotation.JsonProperty;

import lombok.Data;
import lombok.ToString;

@Data
public class F5ConfigurationData {
    @JsonProperty("system-info")
    private SystemVersionDetails systemVersionDetails;

    @JsonProperty("vips")
    private List<VirtualServer> virtualServers = new ArrayList<>();

    @JsonProperty("skipped-vips")
    private List<VirtualServer> skippedVirtualServers = new ArrayList<>();

    private List<Certificate> certificates = new ArrayList<>();
    private List<Peers> peers = new ArrayList<>();
    private List<String> partitions = new ArrayList<>();

    @Data
    public static class SystemVersionDetails {
        public static final String BIGIP = "BIGIP";
        private String product;
        private String version;
        private String build;
        private String edition;
        private String hostname;
    }

    @Data
    @ToString
    public static class VirtualServer {
        private String destination;
        private String partition;
        private String ip;
        private String port;

        @JsonProperty("virtual-server-name")
        private String virtualServerName;

        @JsonProperty("ssl-state")
        private Integer sslState;
    }

    @Data
    public static class Certificate {
        private String cert;
        private String destination;
        private String ip;
        private String port;

        @JsonProperty("cipher-discovery")
        private String cipherDiscovery;

        @JsonProperty("sni")
        private boolean isSni;
    }

    @Data
    public static class Peers {
        @JsonProperty("management-ip")
        private String managementIp;

        @JsonProperty("failover-state")
        private String failoverState;
    }
}
