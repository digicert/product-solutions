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

@Slf4j
@AllArgsConstructor
public class SSHClient {
    private static final Duration TIMEOUT = Duration.ofSeconds(60);

    private final String host;
    private final String username;
    private final String password;

    public SshResponse executeRemoteCommand(String command) throws IOException {
        final var client = getSshClient();
        try {
            client.start();
            try (ClientSession session = openSession(client)) {
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
                final var command = String.format("python - %s", scriptArgs);
                log.info("Executing python script over SSH [name={}]", scriptResourcePath);
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
                        "Error executing command [" + command + "] over SSH [" + username + "@" + host + "]");
            }
            return new SshResponse(
                    responseStream.toString(StandardCharsets.UTF_8), channel.getExitStatus());
        }
    }

    private ClientSession openSession(SshClient client) throws IOException {
        final var session = client.connect(username, host, 22).verify(TIMEOUT).getSession();
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
}
