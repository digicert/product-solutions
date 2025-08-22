<VirtualHost *:80>
    ServerName ${domain_name}
    ServerAlias www.${domain_name}
    
    # Redirect all HTTP traffic to HTTPS
    RewriteEngine On
    RewriteCond %%{HTTPS} off
    RewriteRule ^(.*)$ https://%%{HTTP_HOST}$1 [R=301,L]
</VirtualHost>

<VirtualHost *:443>
    ServerName ${domain_name}
    ServerAlias www.${domain_name}
    
    DocumentRoot /var/www/${domain_name}
    
    # SSL Configuration
    SSLEngine on
    SSLCertificateFile /etc/ssl/certs/${domain_name}-chain.crt
    SSLCertificateKeyFile /etc/ssl/private/${domain_name}.key
    
    # Modern SSL configuration
    SSLProtocol -all +TLSv1.2 +TLSv1.3
    SSLCipherSuite ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384
    SSLHonorCipherOrder off
    
    # Security headers
    Header always set Strict-Transport-Security "max-age=63072000; includeSubDomains; preload"
    Header always set X-Frame-Options DENY
    Header always set X-Content-Type-Options nosniff
    
    # Logging
    ErrorLog $${APACHE_LOG_DIR}/${domain_name}-error.log
    CustomLog $${APACHE_LOG_DIR}/${domain_name}-access.log combined
    
    <Directory /var/www/${domain_name}>
        Options -Indexes +FollowSymLinks
        AllowOverride All
        Require all granted
    </Directory>
</VirtualHost>