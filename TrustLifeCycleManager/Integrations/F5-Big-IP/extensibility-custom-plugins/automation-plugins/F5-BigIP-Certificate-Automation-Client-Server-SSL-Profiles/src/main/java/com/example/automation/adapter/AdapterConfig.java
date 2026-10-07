package com.example.automation.adapter;

import lombok.Builder;
import lombok.Data;

@Data
@Builder
public class AdapterConfig {
    private String protocol;
    private String host;
    private String port;
    private String username;
    private String password;
}
