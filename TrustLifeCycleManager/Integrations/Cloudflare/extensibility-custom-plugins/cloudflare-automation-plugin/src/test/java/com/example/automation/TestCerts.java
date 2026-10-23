package com.example.automation;

import java.math.BigInteger;
import java.security.KeyPair;
import java.security.KeyPairGenerator;
import java.security.cert.X509Certificate;
import java.time.Instant;
import java.util.Date;
import java.util.List;

import org.bouncycastle.asn1.x500.X500Name;
import org.bouncycastle.asn1.x509.Extension;
import org.bouncycastle.asn1.x509.GeneralName;
import org.bouncycastle.asn1.x509.GeneralNames;
import org.bouncycastle.cert.jcajce.JcaX509CertificateConverter;
import org.bouncycastle.cert.jcajce.JcaX509v3CertificateBuilder;
import org.bouncycastle.operator.jcajce.JcaContentSignerBuilder;

import com.example.automation.helper.CloudflareAutomationPluginHelper;

/** Self-signed test certificates (BouncyCastle PKIX, no provider registration needed). */
public final class TestCerts {

    private TestCerts() {
    }

    public record Issued(X509Certificate certificate, String pem, String keyPem, KeyPair keyPair) {
    }

    public static Issued selfSigned(String cn, List<String> sans, Instant notAfter) throws Exception {
        return selfSigned(cn, sans, notAfter, "RSA");
    }

    public static Issued selfSigned(String cn, List<String> sans, Instant notAfter, String algorithm) throws Exception {
        final KeyPair keyPair;
        if ("EC".equals(algorithm)) {
            final var g = KeyPairGenerator.getInstance("EC");
            g.initialize(256);
            keyPair = g.generateKeyPair();
        } else {
            final var g = KeyPairGenerator.getInstance("RSA");
            g.initialize(2048);
            keyPair = g.generateKeyPair();
        }
        final var subject = new X500Name("CN=" + cn + ", O=Test, C=US");
        final var builder = new JcaX509v3CertificateBuilder(subject,
                BigInteger.valueOf(System.nanoTime()), Date.from(Instant.now().minusSeconds(60)), Date.from(notAfter),
                subject, keyPair.getPublic());
        if (sans != null && !sans.isEmpty()) {
            final var names = sans.stream().map(n -> new GeneralName(GeneralName.dNSName, n)).toArray(GeneralName[]::new);
            builder.addExtension(Extension.subjectAlternativeName, false, new GeneralNames(names));
        }
        final var signer = new JcaContentSignerBuilder("EC".equals(algorithm) ? "SHA256withECDSA" : "SHA256withRSA")
                .build(keyPair.getPrivate());
        final var holder = builder.build(signer);
        final var cert = new JcaX509CertificateConverter().getCertificate(holder);
        return new Issued(cert, CloudflareAutomationPluginHelper.toPem("CERTIFICATE", cert.getEncoded()),
                CloudflareAutomationPluginHelper.toPem("PRIVATE KEY", keyPair.getPrivate().getEncoded()), keyPair);
    }
}
