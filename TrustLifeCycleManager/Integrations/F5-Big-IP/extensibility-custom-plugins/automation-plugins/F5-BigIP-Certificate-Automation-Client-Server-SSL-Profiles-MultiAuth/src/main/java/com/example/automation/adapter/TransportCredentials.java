package com.example.automation.adapter;

import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.Base64;
import java.util.Collections;
import java.util.List;
import java.util.Optional;

import com.example.automation.extended.configuration.AuthMode;
import com.example.automation.extended.configuration.MyPluginConfiguration;

import lombok.Getter;
import lombok.extern.slf4j.Slf4j;

/**
 * Resolves the connector configuration into one {@link AdapterConfig} per transport according to the
 * selected {@link AuthMode}. This is the only place that decides which username/password goes to REST
 * and which goes to SSH, so the plugin class and the adapters stay mode-agnostic.
 * <p>
 * Validation problems (for example SEPARATE mode without SSH credentials) are collected rather than thrown
 * so the plugin can still be constructed and report them through Test Connection with a clear message.
 * <p>
 * Secrets manager: when the connector's "Credentials source" is a PAM connector, TLM has already replaced
 * the vault references with the real passwords by the time this class runs, so nothing here differs. The
 * source is only recorded for {@link #describe()}.
 */
@Slf4j
@Getter
public class TransportCredentials {

    private final AuthMode authMode;
    private final AdapterConfig ssh;
    private final AdapterConfig rest;
    private final boolean secretsManagerSource;
    private final List<String> validationErrors;

    private TransportCredentials(AuthMode authMode, AdapterConfig ssh, AdapterConfig rest,
                                 boolean secretsManagerSource, List<String> validationErrors) {
        this.authMode = authMode;
        this.ssh = ssh;
        this.rest = rest;
        this.secretsManagerSource = secretsManagerSource;
        this.validationErrors = Collections.unmodifiableList(validationErrors);
    }

    public static TransportCredentials resolve(MyPluginConfiguration config) {
        final var mode = config.getResolvedAuthMode();
        final var errors = new ArrayList<String>();

        final var primaryUser = config.getUserName();
        final var primaryPassword = decodePassword(config.getPassword());

        String sshUser = primaryUser;
        String sshPassword = primaryPassword;

        switch (mode) {
            case SEPARATE -> {
                if (isBlank(config.getSshUserName())) {
                    errors.add("SSH username is required when the authentication mode is "
                            + "'Separate REST and SSH credentials'");
                }
                if (isBlank(config.getSshPassword())) {
                    errors.add("SSH password is required when the authentication mode is "
                            + "'Separate REST and SSH credentials'");
                }
                sshUser = config.getSshUserName();
                sshPassword = decodePassword(config.getSshPassword());
            }
            case SSH_ONLY -> {
                // Be forgiving: a connector switched from SEPARATE to SSH_ONLY most likely still wants the
                // SSH identity it already had. Fall back to the primary credential otherwise.
                if (config.hasSshCredentials()) {
                    sshUser = config.getSshUserName();
                    sshPassword = decodePassword(config.getSshPassword());
                }
            }
            case SHARED -> {
                if (config.hasSshCredentials()) {
                    log.info("Authentication mode is SHARED; the SSH username/password fields are ignored");
                }
            }
            default -> {
                // AuthMode.from never returns anything else; kept for exhaustiveness.
            }
        }

        if (isBlank(config.getManagementIp())) {
            errors.add("Management IP is required");
        }

        final var sshConfig = AdapterConfig.builder()
                .host(config.getManagementIp())
                .sshPort(config.getResolvedSshPort())
                .username(sshUser)
                .password(sshPassword)
                .build();

        final AdapterConfig restConfig = mode == AuthMode.SSH_ONLY ? null : AdapterConfig.builder()
                .host(config.getManagementIp())
                .port(config.getManagementPort())
                .username(primaryUser)
                .password(primaryPassword)
                .build();

        return new TransportCredentials(mode, sshConfig, restConfig, config.isSecretsManagerSource(), errors);
    }

    /**
     * @return the REST adapter configuration, empty in {@link AuthMode#SSH_ONLY} mode.
     */
    public Optional<AdapterConfig> rest() {
        return Optional.ofNullable(rest);
    }

    public boolean isValid() {
        return validationErrors.isEmpty();
    }

    /**
     * Human-readable description of the identities in use, safe to log (no secrets).
     */
    public String describe() {
        final var source = secretsManagerSource ? "secrets-manager" : "direct";
        final var sshIdentity = String.format("ssh=%s@%s:%d", ssh.getUsername(), ssh.getHost(), ssh.getSshPort());
        if (rest == null) {
            return String.format("mode=%s, credentials=%s, %s, rest=disabled", authMode, source, sshIdentity);
        }
        return String.format("mode=%s, credentials=%s, %s, rest=%s@%s:%s", authMode, source, sshIdentity,
                rest.getUsername(), rest.getHost(), rest.getPort());
    }

    /**
     * TLM hands plugin passwords over base64-encoded. The legacy F5 plugin decoded with
     * {@code Base64.getDecoder().decode(...)}, so we match that contract. If the value
     * doesn't decode cleanly (someone passed plain text), fall back to the original string
     * rather than failing hard.
     */
    static String decodePassword(String raw) {
        if (raw == null || raw.isEmpty()) {
            return raw;
        }
        try {
            return new String(Base64.getDecoder().decode(raw), StandardCharsets.UTF_8);
        } catch (IllegalArgumentException e) {
            return raw;
        }
    }

    private static boolean isBlank(String value) {
        return value == null || value.isBlank();
    }
}
