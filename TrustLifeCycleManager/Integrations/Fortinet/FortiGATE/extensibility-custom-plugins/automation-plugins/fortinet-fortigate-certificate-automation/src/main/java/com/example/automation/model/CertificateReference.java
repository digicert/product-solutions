package com.example.automation.model;

import lombok.AllArgsConstructor;
import lombok.Data;

/**
 * One place on a FortiGate where a local certificate is referenced. FortiOS refuses to delete a
 * certificate while any object references it ({@code q_ref > 0}), so the plugin must repoint every
 * one of them to the renewed certificate before it can remove the old one.
 *
 * <p>References come in two shapes: <em>singleton</em> objects with a string attribute (e.g.
 * {@code vpn.ssl/settings → servercert}) and <em>table</em> entries whose attribute is either a
 * string or a list of {@code {"name": …}} members (e.g. {@code vpn.ipsec/phase1-interface/<tunnel>
 * → certificate}).
 */
@Data
@AllArgsConstructor
public class CertificateReference {

    public enum Type {
        /** {@code vpn.ssl/settings} → {@code servercert} (SSL-VPN portal certificate). */
        SSL_VPN,
        /** {@code system/global} → {@code admin-server-cert} (HTTPS administrative access). */
        ADMIN_HTTPS,
        /** {@code user/setting} → {@code auth-cert} (captive-portal / firewall authentication). */
        USER_AUTH,
        /** {@code system/ftm-push} → {@code server-cert}. */
        FTM_PUSH,
        /** {@code vpn.ipsec/phase1-interface/<tunnel>} → {@code certificate} (list). */
        IPSEC_PHASE1_INTERFACE,
        /** {@code vpn.ipsec/phase1/<tunnel>} → {@code certificate} (list). */
        IPSEC_PHASE1,
        /** {@code firewall/vip/<vip>} → {@code ssl-certificate} (list on 7.x, string on older firmware). */
        FIREWALL_VIP,
        /** {@code firewall/ssl-ssh-profile/<profile>} → {@code server-cert} (list). */
        SSL_SSH_PROFILE
    }

    private Type type;

    /** CMDB path of the object, e.g. {@code vpn.ssl/settings} or {@code vpn.ipsec/phase1-interface}. */
    private String path;

    /** Table entry key ({@code mkey}); null for a singleton object. */
    private String mkey;

    /** Attribute that holds the certificate reference. */
    private String field;

    /** True when the attribute is a list of {@code {"name": …}} members rather than a plain string. */
    private boolean listValued;

    /** Name of the local certificate this reference currently points at. */
    private String certificateName;

    public boolean isSingleton() {
        return mkey == null;
    }

    @Override
    public String toString() {
        return isSingleton()
                ? type.name().toLowerCase().replace('_', '-') + " (" + path + " → " + field + ")"
                : type.name().toLowerCase().replace('_', '-') + " '" + mkey + "' (" + path + " → " + field + ")";
    }
}
