package com.example.automation.adapter;

import lombok.Builder;
import lombok.Data;

/**
 * Connection details for one transport. The REST adapter reads {@code protocol}/{@code host}/{@code port};
 * the SSH adapter reads {@code host}/{@code sshPort}. Both read {@code username}/{@code password}, which
 * may differ between the two instances when the connector uses separate credentials.
 */
@Data
@Builder
public class AdapterConfig {
    private String protocol;
    private String host;
    private String port;
    private Integer sshPort;
    private String username;
    private String password;
}
