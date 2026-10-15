package com.example.automation.extended.configuration;

/**
 * How the connector's credentials map onto the two BIG-IP control planes the plugin talks to.
 * <p>
 * iControl REST is only used by Test Connection (one basic-auth GET on {@code /mgmt/tm/sys/version});
 * every lifecycle operation (CSR, install, validate, refresh) runs tmsh over SSH. So the SSH identity is
 * the one that matters and the REST identity is optional.
 * <ul>
 *   <li>{@link #SHARED}: one username/password for REST and SSH. Default, and the only behaviour the
 *       single-credential plugin offered.</li>
 *   <li>{@link #SEPARATE}: primary username/password for REST, a second pair for SSH. Covers the
 *       "admin for the API, root for the CLI" model.</li>
 *   <li>{@link #SSH_ONLY}: no REST at all. Test Connection runs the SSH probe only. Covers appliances
 *       whose management port is unreachable or where only a CLI identity is handed over.</li>
 * </ul>
 */
public enum AuthMode {
    SHARED,
    SEPARATE,
    SSH_ONLY;

    /**
     * Parses the connector value. Null, blank or unrecognised values resolve to {@link #SHARED} so that
     * connectors created with the single-credential plugin keep working unchanged.
     */
    public static AuthMode from(String raw) {
        if (raw == null || raw.isBlank()) {
            return SHARED;
        }
        final var value = raw.trim().toLowerCase().replace('-', '_').replace(' ', '_');
        return switch (value) {
            case "separate", "split", "rest_and_ssh", "separate_credentials" -> SEPARATE;
            case "ssh_only", "sshonly", "ssh" -> SSH_ONLY;
            default -> SHARED;
        };
    }
}
