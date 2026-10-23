package com.example.automation.adapter;

import java.io.IOException;

import lombok.Getter;

/** A Cloudflare API call that did not succeed (non-2xx, or an envelope with {@code success: false}). */
@Getter
public class CloudflareApiException extends IOException {

    private final int statusCode;

    public CloudflareApiException(String message, int statusCode) {
        super(message);
        this.statusCode = statusCode;
    }

    /** True for HTTP 401/403 — the token is missing, invalid, expired or lacks the permission. */
    public boolean isUnauthorized() {
        return statusCode == 401 || statusCode == 403;
    }
}
