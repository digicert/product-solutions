package com.example.automation.model;

import java.util.List;

import lombok.Data;

/**
 * Fields every device script may add to its JSON output. {@code warnings} are non-fatal problems the
 * script worked around; {@code info} are informational messages (for example whether an HA sync ran).
 */
@Data
public class BaseScriptResponse {
    private List<String> warnings;
    private List<String> info;
}
