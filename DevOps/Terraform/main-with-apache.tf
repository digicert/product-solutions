terraform {
  required_providers {
    digicert = {
      source  = "digicert/digicert"
      version = "0.1.3"
    }
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.0"
    }
    null = {
      source  = "hashicorp/null"
      version = "~> 3.0"
    }
  }
}

# Variables for configuration
variable "domain_name" {
  description = "tlsguru.io"
  type        = string
  default     = "tlsguru.io"
}

# Configure DigiCert provider
provider "digicert" {
  api_key = "01e615c60f4e874a1a6d0d66dc_87d297ee13fb16ac4bade5b94bb6486043532397c921f665b09a1ff689c7ea5c"
  url     = "https://demo.one.digicert.com"
}

# Generate private key
resource "tls_private_key" "server_key" {
  algorithm = "RSA"
  rsa_bits  = 2048
}

# Generate CSR
resource "tls_cert_request" "server_csr" {
  private_key_pem = tls_private_key.server_key.private_key_pem

  subject {
    common_name  = var.domain_name
    organization = "Your Organization"
    country      = "US"
  }

  dns_names = [
    var.domain_name,
    "www.${var.domain_name}"
  ]
}

# Request certificate from DigiCert
resource "digicert_certificate" "server_cert" {
  profile_id  = "f1887d29-ee87-48f7-a873-1a0254dc99a9"
  common_name = var.domain_name
  csr         = tls_cert_request.server_csr.cert_request_pem
}

# Save files locally
resource "local_file" "private_key" {
  content         = tls_private_key.server_key.private_key_pem
  filename        = "${var.domain_name}.key"
  file_permission = "0600"
}

resource "local_file" "certificate" {
  content         = digicert_certificate.server_cert.certificate
  filename        = "${var.domain_name}.crt"
  file_permission = "0644"
}

# For test environment - using certificate without chain
resource "local_file" "certificate_chain" {
  content         = digicert_certificate.server_cert.certificate
  filename        = "${var.domain_name}-chain.crt"
  file_permission = "0644"
}

# Create Apache virtual host configuration file from template
resource "local_file" "apache_vhost_config" {
  content = templatefile("${path.module}/apache-vhost.conf.tpl", {
    domain_name = var.domain_name
  })
  filename        = "${var.domain_name}-apache.conf"
  file_permission = "0644"
}

# Install and configure Apache2 locally
resource "null_resource" "configure_apache_local" {
  # Trigger recreation when certificates change
  triggers = {
    certificate_serial = digicert_certificate.server_cert.serial_number
  }

  # Wait for certificate files to be created
  depends_on = [
    local_file.private_key,
    local_file.certificate,
    local_file.certificate_chain,
    local_file.apache_vhost_config
  ]

  # Install Apache2 and enable SSL module
  provisioner "local-exec" {
    command = <<-EOT
      # Update package list and install Apache2
      sudo apt-get update
      sudo apt-get install -y apache2
      
      # Enable required Apache modules
      sudo a2enmod ssl
      sudo a2enmod rewrite
      sudo a2enmod headers
      
      # Start and enable Apache2 service
      sudo systemctl start apache2
      sudo systemctl enable apache2
    EOT
  }

  # Copy certificates to proper location and set permissions
  provisioner "local-exec" {
    command = <<-EOT
      # Create SSL directories if they don't exist
      sudo mkdir -p /etc/ssl/private
      sudo mkdir -p /etc/ssl/certs
      
      # Copy certificates to proper locations
      sudo cp ${local_file.private_key.filename} /etc/ssl/private/${var.domain_name}.key
      sudo cp ${local_file.certificate_chain.filename} /etc/ssl/certs/${var.domain_name}-chain.crt
      
      # Set proper permissions and ownership
      sudo chmod 600 /etc/ssl/private/${var.domain_name}.key
      sudo chmod 644 /etc/ssl/certs/${var.domain_name}-chain.crt
      sudo chown root:root /etc/ssl/private/${var.domain_name}.key
      sudo chown root:root /etc/ssl/certs/${var.domain_name}-chain.crt
    EOT
  }

  # Copy Apache configuration
  provisioner "local-exec" {
    command = <<-EOT
      # Copy the Apache virtual host configuration
      sudo cp ${local_file.apache_vhost_config.filename} /etc/apache2/sites-available/${var.domain_name}-ssl.conf
    EOT
  }

  # Create document root and sample index page
  provisioner "local-exec" {
    command = <<-EOT
      # Create document root directory
      sudo mkdir -p /var/www/${var.domain_name}
      
      # Create a sample index page
      cat > /tmp/index.html <<'HTML'
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Welcome to ${var.domain_name}</title>
    <style>
        body {
            font-family: Arial, sans-serif;
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            color: white;
            display: flex;
            justify-content: center;
            align-items: center;
            height: 100vh;
            margin: 0;
        }
        .container {
            text-align: center;
            padding: 2rem;
            background: rgba(255, 255, 255, 0.1);
            border-radius: 10px;
            backdrop-filter: blur(10px);
        }
        h1 { margin-bottom: 1rem; }
        .success { color: #4ade80; font-size: 3rem; }
        .info { margin-top: 2rem; font-size: 0.9rem; opacity: 0.9; }
    </style>
</head>
<body>
    <div class="container">
        <div class="success">✓</div>
        <h1>Welcome to ${var.domain_name}</h1>
        <p>SSL certificate successfully configured with Apache2!</p>
        <div class="info">
            <p>Certificate Serial: ${digicert_certificate.server_cert.serial_number}</p>
            <p>Secured with DigiCert SSL</p>
        </div>
    </div>
</body>
</html>
HTML
      
      sudo mv /tmp/index.html /var/www/${var.domain_name}/index.html
      
      # Set proper ownership
      sudo chown -R www-data:www-data /var/www/${var.domain_name}
    EOT
  }

  # Enable the site and reload Apache
  provisioner "local-exec" {
    command = <<-EOT
      # Enable the new SSL site
      sudo a2ensite ${var.domain_name}-ssl.conf
      
      # Disable default site (optional)
      sudo a2dissite 000-default.conf || true
      
      # Test Apache configuration
      sudo apache2ctl configtest
      
      # Reload Apache to apply changes
      sudo systemctl reload apache2
      
      echo "Apache2 has been configured successfully!"
      echo "You can access your site at:"
      echo "  - http://${var.domain_name} (will redirect to HTTPS)"
      echo "  - https://${var.domain_name}"
    EOT
  }
}

# Optional: Configure local firewall
resource "null_resource" "configure_firewall_local" {
  depends_on = [null_resource.configure_apache_local]

  provisioner "local-exec" {
    command = <<-EOT
      # Check if UFW is installed and configure it
      if command -v ufw &> /dev/null; then
        sudo ufw allow 'Apache Full' || true
        sudo ufw allow 'OpenSSH' || true
        echo "Firewall rules configured (if UFW is active)"
      else
        echo "UFW not installed, skipping firewall configuration"
      fi
    EOT
  }
}

# Create a script for testing the SSL configuration
resource "local_file" "test_ssl_script" {
  content = <<-EOT
#!/bin/bash
echo "Testing SSL Configuration for ${var.domain_name}"
echo "================================================"
echo ""
echo "1. Apache Status:"
sudo systemctl status apache2 --no-pager | head -n 5
echo ""
echo "2. SSL Module Status:"
apache2ctl -M 2>/dev/null | grep ssl
echo ""
echo "3. Virtual Host Configuration:"
apache2ctl -S 2>&1 | grep ${var.domain_name}
echo ""
echo "4. Certificate Information:"
openssl x509 -in /etc/ssl/certs/${var.domain_name}-chain.crt -noout -subject -dates
echo ""
echo "5. Test HTTPS Connection (localhost):"
curl -k -I https://localhost 2>/dev/null | head -n 1
echo ""
echo "6. Apache Error Log (last 5 lines):"
sudo tail -n 5 /var/log/apache2/error.log
echo ""
echo "Note: For full functionality, ensure ${var.domain_name} points to this server's IP address."
EOT
  filename        = "test-ssl-setup.sh"
  file_permission = "0755"
}

# Outputs
output "certificate_serial_number" {
  value = digicert_certificate.server_cert.serial_number
}

output "files_created" {
  value = {
    private_key       = "${var.domain_name}.key"
    certificate       = "${var.domain_name}.crt"
    certificate_chain = "${var.domain_name}-chain.crt"
    apache_config     = "${var.domain_name}-apache.conf"
    test_script       = "test-ssl-setup.sh"
  }
}

output "apache_configuration" {
  value = {
    virtual_host_file = "/etc/apache2/sites-available/${var.domain_name}-ssl.conf"
    document_root     = "/var/www/${var.domain_name}"
    ssl_cert_path     = "/etc/ssl/certs/${var.domain_name}-chain.crt"
    ssl_key_path      = "/etc/ssl/private/${var.domain_name}.key"
  }
}

output "access_info" {
  value = <<-EOT
  
  ========================================
  Apache2 SSL Setup Complete!
  ========================================
  
  Access URLs:
    - http://${var.domain_name} (redirects to HTTPS)
    - https://${var.domain_name}
    - https://localhost (for local testing)
  
  Test your setup:
    ./test-ssl-setup.sh
  
  Useful commands:
    - Check Apache status: sudo systemctl status apache2
    - View error logs: sudo tail -f /var/log/apache2/${var.domain_name}-error.log
    - Test SSL: openssl s_client -connect localhost:443 -servername ${var.domain_name}
    - Reload Apache: sudo systemctl reload apache2
  
  Note: Ensure ${var.domain_name} points to this server's IP address for domain access.
  EOT
}