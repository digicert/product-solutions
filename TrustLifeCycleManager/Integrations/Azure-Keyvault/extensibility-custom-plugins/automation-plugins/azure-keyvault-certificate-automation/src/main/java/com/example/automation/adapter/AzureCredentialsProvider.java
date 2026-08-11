package com.example.automation.adapter;

import com.azure.core.http.netty.NettyAsyncHttpClientBuilder;
import com.azure.identity.ClientSecretCredential;
import com.azure.identity.ClientSecretCredentialBuilder;

import io.netty.handler.ssl.SslContextBuilder;
import io.netty.handler.ssl.util.InsecureTrustManagerFactory;

import lombok.Getter;
import lombok.extern.slf4j.Slf4j;

import reactor.netty.http.client.HttpClient;

/**
 * Builds the Azure AD {@link ClientSecretCredential} and the Netty HTTP client used by the Key Vault
 * {@code CertificateClient}. Ported from the legacy DigiCert Azure Key Vault delivery connector so
 * the authentication path is identical to the proven connector.
 *
 * <p>Supplying an explicit Netty {@link com.azure.core.http.HttpClient} to the SDK client builders is
 * deliberate: it makes the plugin proxy-aware (via system properties) and sidesteps the Azure SDK's
 * {@code HttpClientProvider} {@code ServiceLoader} lookup, which is fragile inside a shaded fat jar.
 */
@Getter
@Slf4j
public class AzureCredentialsProvider {

    private final ClientSecretCredential clientSecretCredential;

    public AzureCredentialsProvider(AdapterConfig config) {
        this.clientSecretCredential =
                new ClientSecretCredentialBuilder()
                        .clientId(config.getClientId())
                        .clientSecret(config.getClientSecret())
                        .tenantId(config.getTenantId())
                        .build();
    }

    /**
     * Netty HTTP client builder that honours JVM proxy system properties and trusts all TLS
     * certificates, matching the legacy connector (supports outbound proxies / TLS-inspecting
     * gateways in front of the Azure endpoints).
     */
    public static NettyAsyncHttpClientBuilder createHttpClientBuilder() {
        log.info("Creating Azure HttpClientBuilder (proxy-aware, InsecureTrustManagerFactory)");
        SslContextBuilder sslContextBuilder =
                SslContextBuilder.forClient().trustManager(InsecureTrustManagerFactory.INSTANCE);

        HttpClient httpClient =
                HttpClient.create()
                        .proxyWithSystemProperties()
                        .secure(sslProviderSpec -> sslProviderSpec.sslContext(sslContextBuilder));

        return new NettyAsyncHttpClientBuilder(httpClient);
    }
}
