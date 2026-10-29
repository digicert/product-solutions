package com.example.automation.extended.configuration;

import static org.junit.jupiter.api.Assertions.assertEquals;

import org.junit.jupiter.api.DisplayName;
import org.junit.jupiter.api.Test;

class AuthModeTest {

    // ── Defaults ──────────────────────────────────────────────────────────────

    @Test
    @DisplayName("null resolves to SHARED so connectors saved with the single-credential plugin keep working")
    void nullIsShared() {
        assertEquals(AuthMode.SHARED, AuthMode.from(null));
    }

    @Test
    @DisplayName("blank resolves to SHARED")
    void blankIsShared() {
        assertEquals(AuthMode.SHARED, AuthMode.from("   "));
    }

    @Test
    @DisplayName("unknown values resolve to SHARED rather than failing")
    void unknownIsShared() {
        assertEquals(AuthMode.SHARED, AuthMode.from("kerberos"));
    }

    // ── Aliases ───────────────────────────────────────────────────────────────

    @Test
    @DisplayName("separate, split, rest_and_ssh and separate_credentials map to SEPARATE")
    void separateAliases() {
        assertEquals(AuthMode.SEPARATE, AuthMode.from("separate"));
        assertEquals(AuthMode.SEPARATE, AuthMode.from("split"));
        assertEquals(AuthMode.SEPARATE, AuthMode.from("rest_and_ssh"));
        assertEquals(AuthMode.SEPARATE, AuthMode.from("separate_credentials"));
    }

    @Test
    @DisplayName("ssh_only, sshonly and ssh map to SSH_ONLY")
    void sshOnlyAliases() {
        assertEquals(AuthMode.SSH_ONLY, AuthMode.from("ssh_only"));
        assertEquals(AuthMode.SSH_ONLY, AuthMode.from("sshonly"));
        assertEquals(AuthMode.SSH_ONLY, AuthMode.from("ssh"));
    }

    @Test
    @DisplayName("case, surrounding whitespace, hyphens and spaces are normalised")
    void normalisation() {
        assertEquals(AuthMode.SSH_ONLY, AuthMode.from("  SSH-Only "));
        assertEquals(AuthMode.SEPARATE, AuthMode.from("Rest and SSH"));
        assertEquals(AuthMode.SHARED, AuthMode.from("Shared"));
    }
}
