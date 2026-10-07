package com.example.automation.util.ssh;

import lombok.AllArgsConstructor;
import lombok.Data;

@Data
@AllArgsConstructor
public class SshResponse {
    private String output;
    private Integer exitStatus;

    public boolean isSuccess() {
        return exitStatus != null && exitStatus == 0;
    }
}
