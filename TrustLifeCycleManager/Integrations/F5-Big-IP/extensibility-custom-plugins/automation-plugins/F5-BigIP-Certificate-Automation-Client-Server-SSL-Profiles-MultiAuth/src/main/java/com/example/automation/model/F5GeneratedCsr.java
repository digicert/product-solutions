package com.example.automation.model;

import lombok.Data;
import lombok.EqualsAndHashCode;

@Data
@EqualsAndHashCode(callSuper = false)
public class F5GeneratedCsr extends BaseScriptResponse {
    private String csr;
}
