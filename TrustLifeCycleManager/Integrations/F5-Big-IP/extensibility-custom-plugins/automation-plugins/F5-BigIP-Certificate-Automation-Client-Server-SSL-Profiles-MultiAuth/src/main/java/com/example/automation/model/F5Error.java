package com.example.automation.model;

import com.fasterxml.jackson.annotation.JsonProperty;

import lombok.Data;
import lombok.EqualsAndHashCode;

@Data
@EqualsAndHashCode(callSuper = true)
public class F5Error extends BaseScriptResponse {
    @JsonProperty("error")
    private String message;

    private String code;
}
