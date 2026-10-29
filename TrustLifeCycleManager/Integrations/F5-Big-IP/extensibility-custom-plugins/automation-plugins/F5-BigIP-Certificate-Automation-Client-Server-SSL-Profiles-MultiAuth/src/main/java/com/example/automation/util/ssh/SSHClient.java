package com.example.automation.util.ssh;

import static org.apache.sshd.core.CoreModuleProperties.HEARTBEAT_INTERVAL;
import static org.apache.sshd.core.CoreModuleProperties.IDLE_TIMEOUT;

import java.io.BufferedReader;
import java.io.ByteArrayInputStream;
import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.InputStreamReader;
import java.nio.charset.StandardCharsets;
import java.time.Duration;
import java.util.EnumSet;
import java.util.stream.Collectors;

import org.apache.sshd.client.SshClient;
import org.apache.sshd.client.channel.ClientChannelEvent;
import org.apache.sshd.client.session.ClientSession;
import org.apache.sshd.common.SshException;

import lombok.AllArgsConstructor;
import lombok.extern.slf4j.Slf4j;

/**
 * Minimal Apache MINA SSHD wrapper: one session per call, password authentication only, stderr
 * merged into stdout.
 * <p>
 * Login-shell handling: BIG-IP accounts whose Terminal Access is "tmsh" (common for AD/LDAP/RADIUS
 * remote-role users) land every exec channel in tmsh rather than bash, so a plain shell command is
 * rejected. {@link #isTmshShell(ClientSession)} probes this once per session and, when detected,
 * every command is wrapped as {@code run /util bash -c '<command>'} so the scripts still execute
 * without changing the account on the appliance.
 */
@Slf4j
@AllArgsConstructor
public class SSHClient {
    private static final Duration TIMEOUT = Duration.ofSeconds(60);

    /** Probe that only produces this marker when the exec channel is a tmsh shell. */
    static final String TMSH_PROBE_COMMAND = "run /util bash -c 'echo %0'";
    static final String TMSH_PROBE_MARKER = "%0";

    private final String host;
    private final int port;
    private final String username;
    private final String password;

    public SshResponse executeRemoteCommand(String command) throws IOException {
        final var client = getSshClient();
        try {
            client.start();
            try (ClientSession session = openSession(client)) {
                if (isTmshShell(session)) {
                    command = wrapForTmsh(command);
                }
                return executeCommand(session, command, null);
            }
        } finally {
            client.stop();
        }
    }

    public SshResponse executePythonScript(String scriptResourcePath, String scriptArgs) throws IOException {
        final var client = getSshClient();
        try {
            client.start();
            try (ClientSession session = openSession(client)) {
                final InputStream inputStream = this.getClass().getResourceAsStream(scriptResourcePath);
                if (inputStream == null) {
                    throw new IOException("Script not found on classpath: " + scriptResourcePath);
                }
                final String script;
                try (BufferedReader reader = new BufferedReader(
                        new InputStreamReader(inputStream, StandardCharsets.UTF_8))) {
                    script = reader.lines().collect(Collectors.joining("\n"));
                }
                var command = String.format("python - %s", scriptArgs);
                log.info("Executing python script over SSH [name={}]", scriptResourcePath);
                if (isTmshShell(session)) {
                    command = wrapForTmsh(command);
                }
                return executeCommand(session, command, script);
            }
        } finally {
            client.stop();
        }
    }

    private SshResponse executeCommand(ClientSession session, String command, String in) throws IOException {
        try (var channel = session.createExecChannel(command);
             var responseStream = new ByteArrayOutputStream()) {
            if (in != null && !in.isEmpty()) {
                channel.setIn(new ByteArrayInputStream(in.getBytes(StandardCharsets.UTF_8)));
            }
            channel.setOut(responseStream);
            channel.setRedirectErrorStream(true);
            channel.open().verify(TIMEOUT);
            channel.waitFor(EnumSet.of(ClientChannelEvent.CLOSED), 0L);
            if (channel.getExitStatus() == null) {
                throw new SshException(
                        "Error executing command [" + command + "] over SSH [" + username + "@" + host + ":" + port + "]");
            }
            return new SshResponse(
                    responseStream.toString(StandardCharsets.UTF_8), channel.getExitStatus());
        }
    }

    private ClientSession openSession(SshClient client) throws IOException {
        final var session = client.connect(username, host, port).verify(TIMEOUT).getSession();
        session.addPasswordIdentity(password);
        session.auth().verify(TIMEOUT);
        return session;
    }

    private static SshClient getSshClient() {
        final var client = SshClient.setUpDefaultClient();
        client.getProperties().put(HEARTBEAT_INTERVAL.getName(), TIMEOUT.toMillis());
        client.getProperties().put(IDLE_TIMEOUT.getName(), TIMEOUT.toMillis());
        return client;
    }

    /**
     * In bash the probe is a syntax error (non-zero exit, no marker). In tmsh it runs bash and echoes
     * the literal marker, which tells us every later command needs wrapping.
     */
    private boolean isTmshShell(ClientSession session) {
        try {
            final var response = executeCommand(session, TMSH_PROBE_COMMAND, null);
            final var tmsh = response.isSuccess() && response.getOutput().trim().contains(TMSH_PROBE_MARKER);
            if (tmsh) {
                log.info("tmsh login shell detected for {}@{}:{}; commands will be wrapped with run /util bash -c",
                        username, host, port);
            }
            return tmsh;
        } catch (Exception e) {
            log.warn("Could not determine login shell type for {}@{}:{}; assuming bash", username, host, port, e);
            return false;
        }
    }

    /**
     * Wraps a bash command so tmsh executes it. Single quotes inside the command are closed, escaped
     * and reopened ({@code '\''}) so the wrapping quotes stay balanced.
     */
    static String wrapForTmsh(String command) {
        final var escaped = command == null ? "" : command.replace("'", "'\\''");
        return "run /util bash -c '" + escaped + "'";
    }
}
