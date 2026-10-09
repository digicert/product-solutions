package com.example.automation.adapter;

import java.io.ByteArrayOutputStream;
import java.nio.charset.StandardCharsets;
import java.time.Duration;
import java.util.EnumSet;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

import org.apache.sshd.client.SshClient;
import org.apache.sshd.client.channel.ChannelExec;
import org.apache.sshd.client.channel.ChannelShell;
import org.apache.sshd.client.channel.ClientChannelEvent;
import org.apache.sshd.client.keyverifier.AcceptAllServerKeyVerifier;
import org.apache.sshd.client.session.ClientSession;

import lombok.extern.slf4j.Slf4j;

/**
 * Read-only SSH access to the FortiWeb CLI, used solely to obtain certificate <em>bodies</em>.
 *
 * <p>FortiWeb's REST API lists local certificates but never returns their PEM (and
 * {@code certificate.local.download} refuses imported certificates), yet TLM only inventories a
 * certificate when it receives the PEM. The CLI does print it:
 * <pre>
 *   FortiWeb # show system certificate local
 *   config system certificate local
 *     edit "cer"
 *       set certificate "-----BEGIN CERTIFICATE-----
 *   MIIC7jCCAlegAwIBAgIBADANBgkqhkiG9w0BAQsFADCBkzELMAkGA1UEBhMCdXMx
 *   ...
 *   -----END CERTIFICATE-----
 *   "
 *       set private-key "-----BEGIN ENCRYPTED PRIVATE KEY-----   (ignored - encrypted, never needed)
 *   ...
 *     next
 *   end
 * </pre>
 * So this client logs in with the same administrator credentials the REST calls use, runs that one
 * {@code show} command, and hands the output to {@link #parseCertificates(String)}. Nothing is ever
 * written to the configuration over SSH.
 *
 * <p>The command is first sent over an SSH <em>exec</em> channel (what {@code ssh host "cmd"} does);
 * if the appliance does not honour exec channels the client falls back to an interactive shell,
 * waits for the {@code #} prompt, sends the command and answers any {@code --More--} pager prompt.
 * Host keys are accepted without verification (mirrors the trust-all TLS towards the REST API).
 */
@Slf4j
public class FortiWebSshClient {

    public static final String SHOW_LOCAL_CERTS = "show system certificate local";

    private static final Duration CONNECT_TIMEOUT = Duration.ofSeconds(20);
    private static final Duration AUTH_TIMEOUT = Duration.ofSeconds(20);
    private static final Duration COMMAND_TIMEOUT = Duration.ofSeconds(90);
    /**
     * Exec channels either answer within a few seconds or are not supported at all (the channel
     * opens but nothing ever comes back), so give up early and fall back to the shell.
     */
    private static final Duration EXEC_TIMEOUT = Duration.ofSeconds(30);

    /** A FortiWeb prompt: {@code FortiWeb # } or {@code hostname (root) # } at the end of the buffer. */
    private static final Pattern PROMPT = Pattern.compile("(?m)^[^\\r\\n]*#\\s?$");
    private static final Pattern EDIT_BLOCK = Pattern.compile(
            "edit\\s+\"([^\"]+)\"([\\s\\S]*?)(?:\\n\\s*next\\b|\\n\\s*end\\b)");
    private static final Pattern PEM_CERT = Pattern.compile(
            "-----BEGIN CERTIFICATE-----[\\s\\S]+?-----END CERTIFICATE-----");

    private final String host;
    private final int port;
    private final String username;
    private final String password;

    public FortiWebSshClient(AdapterConfig config) {
        this.host = config.getHost();
        this.port = config.getSshPort();
        this.username = config.getUsername();
        this.password = config.getPassword();
    }

    /** Runs {@value #SHOW_LOCAL_CERTS} and returns certificate name → PEM for every local certificate. */
    public Map<String, String> fetchCertificatePems() throws Exception {
        final var output = run(SHOW_LOCAL_CERTS);
        final var pems = parseCertificates(output);
        log.info("CLI '{}' over SSH returned {} certificate bod(y/ies): {}", SHOW_LOCAL_CERTS, pems.size(), pems.keySet());
        return pems;
    }

    /** Executes one CLI command and returns its output (exec channel, shell fallback). */
    public String run(String command) throws Exception {
        try (SshClient client = SshClient.setUpDefaultClient()) {
            client.setServerKeyVerifier(AcceptAllServerKeyVerifier.INSTANCE);
            client.start();
            log.info("SSH connecting to {}:{} as {} for read-only CLI access", host, port, username);
            try (ClientSession session = client.connect(username, host, port).verify(CONNECT_TIMEOUT).getSession()) {
                session.addPasswordIdentity(password);
                session.auth().verify(AUTH_TIMEOUT);

                String output = null;
                try {
                    output = exec(session, command);
                } catch (Exception e) {
                    log.info("SSH exec channel failed ({}); falling back to an interactive shell", e.getMessage());
                }
                if (output == null || output.isBlank()) {
                    log.info("SSH exec channel returned nothing; falling back to an interactive shell");
                    output = shell(session, command);
                }
                return output;
            }
        }
    }

    private static String exec(ClientSession session, String command) throws Exception {
        try (ChannelExec channel = session.createExecChannel(command)) {
            final var out = new ByteArrayOutputStream();
            final var err = new ByteArrayOutputStream();
            channel.setOut(out);
            channel.setErr(err);
            channel.open().verify(EXEC_TIMEOUT);
            // Poll so a device that streams the output but never closes the channel still returns
            // as soon as the "end" of the config block has arrived.
            final long deadline = System.currentTimeMillis() + EXEC_TIMEOUT.toMillis();
            while (System.currentTimeMillis() < deadline) {
                final var events = channel.waitFor(
                        EnumSet.of(ClientChannelEvent.CLOSED, ClientChannelEvent.EOF, ClientChannelEvent.EXIT_STATUS),
                        Duration.ofSeconds(1));
                if (events.contains(ClientChannelEvent.CLOSED) || events.contains(ClientChannelEvent.EOF)
                        || events.contains(ClientChannelEvent.EXIT_STATUS)) {
                    break;
                }
                if (out.toString(StandardCharsets.UTF_8).matches("(?s).*\\nend\\s*$")) {
                    break;
                }
            }
            final var text = out.toString(StandardCharsets.UTF_8);
            if (err.size() > 0) {
                log.debug("SSH exec stderr: {}", err.toString(StandardCharsets.UTF_8).trim());
            }
            return text;
        }
    }

    private static String shell(ClientSession session, String command) throws Exception {
        try (ChannelShell channel = session.createShellChannel()) {
            channel.setPtyType("vt100");
            channel.setPtyColumns(512);
            channel.setPtyLines(200);
            final var out = new ByteArrayOutputStream();
            channel.setOut(out);
            channel.setErr(out);
            channel.open().verify(COMMAND_TIMEOUT);

            waitFor(out, PROMPT, Duration.ofSeconds(20), channel);
            final int start = out.size();
            channel.getInvertedIn().write((command + "\n").getBytes(StandardCharsets.UTF_8));
            channel.getInvertedIn().flush();
            waitFor(out, PROMPT, COMMAND_TIMEOUT, channel, start);
            try {
                channel.getInvertedIn().write("exit\n".getBytes(StandardCharsets.UTF_8));
                channel.getInvertedIn().flush();
            } catch (Exception ignored) {
                // session is being torn down anyway
            }
            var text = out.toString(StandardCharsets.UTF_8).substring(start);
            // strip pager artefacts and terminal control characters
            text = text.replace("--More--", "").replaceAll("[\\x08\\r]", "").replaceAll("\\x1B\\[[0-9;]*[A-Za-z]", "");
            return text;
        }
    }

    private static void waitFor(ByteArrayOutputStream out, Pattern pattern, Duration timeout, ChannelShell channel)
            throws Exception {
        waitFor(out, pattern, timeout, channel, 0);
    }

    /** Polls the shell buffer until {@code pattern} matches after offset {@code from}, answering the pager. */
    private static void waitFor(ByteArrayOutputStream out, Pattern pattern, Duration timeout, ChannelShell channel,
                                int from) throws Exception {
        final long deadline = System.currentTimeMillis() + timeout.toMillis();
        int lastLen = -1;
        while (System.currentTimeMillis() < deadline) {
            final var text = out.toString(StandardCharsets.UTF_8);
            final var tail = text.length() > from ? text.substring(from) : "";
            if (tail.contains("--More--") && text.length() != lastLen) {
                channel.getInvertedIn().write(" ".getBytes(StandardCharsets.UTF_8));
                channel.getInvertedIn().flush();
            }
            // Ignore the echoed command line itself; require the prompt on a later line.
            final var body = tail.indexOf('\n') >= 0 ? tail.substring(tail.indexOf('\n') + 1) : "";
            if ((from == 0 && pattern.matcher(tail).find()) || (from > 0 && pattern.matcher(body).find())) {
                return;
            }
            lastLen = text.length();
            Thread.sleep(200);
        }
        throw new IllegalStateException("Timed out after " + timeout.toSeconds() + "s waiting for the FortiWeb CLI prompt");
    }

    /**
     * Parses {@code show system certificate local} output into name → PEM. Blocks without a
     * certificate (e.g. a pending CSR) are skipped; the encrypted private key is never read.
     */
    public static Map<String, String> parseCertificates(String cliOutput) {
        final Map<String, String> result = new LinkedHashMap<>();
        if (cliOutput == null || cliOutput.isBlank()) {
            return result;
        }
        final var normalized = cliOutput.replace("\r", "");
        final Matcher block = EDIT_BLOCK.matcher(normalized);
        while (block.find()) {
            final var name = block.group(1);
            final var body = block.group(2);
            // Only the "set certificate" value - never the private-key block that follows it.
            final int certIdx = body.indexOf("set certificate");
            final int keyIdx = body.indexOf("set private-key");
            final var certPart = certIdx < 0 ? "" : body.substring(certIdx, keyIdx > certIdx ? keyIdx : body.length());
            final Matcher pem = PEM_CERT.matcher(certPart);
            if (pem.find()) {
                result.put(name, pem.group().strip() + "\n");
            }
        }
        return result;
    }
}
